import Foundation
import Observation
import FleetCore

/// Bot profile management state + operations for the roster/create/edit/
/// sections surfaces. Owned by `AppEnvironment` (composition-root state) so
/// sheets survive navigation; all writes go through the injected
/// `BotProfileManaging` seam, never FleetNetworking directly.
@MainActor
@Observable
public final class BotManagementController {
    // MARK: Observable state

    /// Sections registry per gateway (Fleet-owned `bot-sections-v1` ui_meta
    /// on the gateway's default profile; Desktop's registry is plugin-local
    /// and never syncs — rendering parity is identical because unknown
    /// sectionIds render unassigned either way).
    public private(set) var sectionsByGateway: [GatewayID: [BotSection]] = [:]
    public private(set) var sectionsSyncErrors: [GatewayID: String] = [:]

    /// In-flight markers.
    public private(set) var syncingSections: Set<GatewayID> = []

    /// Create-bot flow state.
    public private(set) var isCreatingBot = false
    public private(set) var lastCreateError: String?

    /// Edit flow state (per route, one sheet at a time in practice).
    public private(set) var editOutcomes: [Route: BotProfileEditOutcome] = [:]
    public private(set) var editErrors: [Route: String] = [:]

    /// Avatar bytes cache per route (nil = not fetched; the authoritative
    /// flag is the roster's hasAvatar — bytes are a display cache only).
    public private(set) var avatarDataByRoute: [Route: Data] = [:]

    // MARK: Injected seams

    @ObservationIgnored private var avatarLoads: Set<Route> = []
    @ObservationIgnored private var avatarFetchedAt: [Route: Date] = [:]
    @ObservationIgnored private var avatarSlots = 0
    @ObservationIgnored private var avatarGenerations: [Route: Int] = [:]
    @ObservationIgnored private var avatarWaiters: [CheckedContinuation<Void, Never>] = []
    private let factory: FleetBotProfileFactory?
    @ObservationIgnored private var seams: [GatewayID: any BotProfileManaging] = [:]

    public func retireGateway(_ id: GatewayID) async {
        if let seam = seams.removeValue(forKey: id) {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
    }
    private var gatewayProvider: @MainActor () -> [FleetGateway]

    public init(
        factory: FleetBotProfileFactory?,
        gatewayProvider: @escaping @MainActor () -> [FleetGateway] = { [] }
    ) {
        self.factory = factory
        self.gatewayProvider = gatewayProvider
    }

    /// Late-bound gateway provider (the owning environment wires itself in
    /// after its own stored properties are initialized — Swift forbids
    /// capturing `self` in an escaping closure during init).
    public func setGatewayProvider(_ provider: @escaping @MainActor () -> [FleetGateway]) {
        gatewayProvider = provider
    }

    /// Seam for a gateway (nil when no factory wired or gateway absent —
    /// callers render honest unavailable states, fail closed).
    public func seam(for gatewayID: GatewayID) -> (any BotProfileManaging)? {
        if let existing = seams[gatewayID] { return existing }
        guard let factory,
              let gateway = gatewayProvider().first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        seams[gatewayID] = seam
        return seam
    }

    // MARK: - Sections registry (D10)

    /// Load a gateway's Fleet section registry (default profile ui_meta).
    /// Never throws to the caller — errors land in `sectionsSyncErrors`.
    public func loadSections(from gatewayID: GatewayID) async {
        guard !syncingSections.contains(gatewayID) else { return }
        syncingSections.insert(gatewayID)
        defer { syncingSections.remove(gatewayID) }
        guard let loader = seam(for: gatewayID) as? BotSectionRegistryLoading else {
            sectionsSyncErrors[gatewayID] = "Section sync needs a newer Hermes gateway"
            return
        }
        do {
            let registry = try await loader.loadSectionRegistry()
            sectionsByGateway[gatewayID] = registry.sections
            sectionsSyncErrors[gatewayID] = nil
        } catch {
            sectionsByGateway[gatewayID] = []
            sectionsSyncErrors[gatewayID] = Redaction.safeErrorDescription(error)
        }
    }

    /// Write a new registry (create/rename/reorder/delete) with per-key CAS.
    /// On conflict the current registry is loaded and a typed conflict is
    /// thrown — never a silent overwrite.
    public func saveSections(
        _ sections: [BotSection], on gatewayID: GatewayID
    ) async throws {
        guard let writer = seam(for: gatewayID) as? BotSectionRegistryLoading & BotSectionRegistryWriting else {
            throw BotSectionSyncError.unsupported("Section sync needs a newer Hermes gateway")
        }
        let current = try await writer.loadSectionRegistry()
        let encoded = BotSectionRegistry.encode(sections)
        _ = try await writer.writeSectionRegistry(
            value: encoded, expectedRevision: current.revision)
        sectionsByGateway[gatewayID] = sections
        sectionsSyncErrors[gatewayID] = nil
    }

    /// Move one bot to a section (or unassign) — a per-bot ui_meta CAS write
    /// on the bot's OWN metadata (`sectionId` field), identical to every
    /// other metadata edit.
    public func moveBot(
        _ bot: FleetBot, toSection sectionID: String?
    ) async throws -> BotProfileEditOutcome {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unsupported("Profile management is unavailable on this gateway")
        }
        var metadata = bot.botModeMetadata ?? BotModeMetadata()
        metadata.sectionID = sectionID
        let edit = BotProfileEdit(
            metadata: metadata,
            metadataExpectedRevision: bot.uiMetaRevisions?[BotModeContract.botsMetaKey],
            previousMetadataRaw: bot.uiMeta?[BotModeContract.botsMetaKey])
        let outcome = try await seam.configureProfile(
            bot.route.profileSlug.rawValue, edit: edit)
        editOutcomes[bot.route] = outcome
        return outcome
    }

    // MARK: - Create (D05/D06)

    /// Create a bot on the TARGET gateway (never switches the app's active
    /// gateway — requests route to the chosen gateway's seam). On success a
    /// fresh canonical Bot Chat does not exist yet; the roster refresh after
    /// creation shows the new profile, and the first tap creates the chat.
    public func createBot(_ spec: BotCreateSpec, on gatewayID: GatewayID) async throws -> String {
        guard let seam = seam(for: gatewayID) else {
            throw BotSectionSyncError.unsupported("Profile management is unavailable on this gateway")
        }
        isCreatingBot = true
        defer { isCreatingBot = false }
        lastCreateError = nil
        do {
            let name = try await seam.createProfile(spec)
            return name
        } catch {
            lastCreateError = Redaction.safeErrorDescription(error)
            throw error
        }
    }

    // MARK: - Edit (D07)

    /// Load the editable surface for one bot.
    public func describeBot(_ bot: FleetBot) async throws -> BotProfileDescription {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        return try await seam.describeProfile(bot.route.profileSlug.rawValue)
    }

    /// Apply an edit; a model-confirmation requirement is returned for the
    /// caller to surface as a native confirmationDialog (never bypassed).
    public func applyEdit(
        _ edit: BotProfileEdit, to bot: FleetBot
    ) async throws -> BotProfileEditOutcome {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        do {
            let outcome = try await seam.configureProfile(
                bot.route.profileSlug.rawValue, edit: edit)
            editOutcomes[bot.route] = outcome
            editErrors[bot.route] = nil
            return outcome
        } catch let error as LocalizedError {
            editErrors[bot.route] = error.errorDescription
            throw error
        }
    }

    /// Resend a model-only edit after explicit user confirmation.
    public func confirmModelEdit(
        _ edit: BotProfileEdit, for bot: FleetBot
    ) async throws -> BotProfileEditOutcome {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        let outcome = try await seam.configureProfile(
            bot.route.profileSlug.rawValue,
            edit: edit.modelOnlyResend,
            confirmExpensiveModel: true)
        editOutcomes[bot.route] = outcome
        return outcome
    }

    // MARK: - Avatar (D08, #7 unified appearance save)

    /// Avatar appearance save outcome (#7): the coordinated metadata +
    /// asset transaction reconciled against the refreshed roster. A
    /// partial application is NEVER reported as plain success.
    public struct BotAvatarAppearanceResult: Hashable, Sendable {
        /// The profiles.configure outcome (metadata + carried sections).
        public var editOutcome: BotProfileEditOutcome
        /// The asset mutation (replacement/clear) applied when one was staged.
        public var assetApplied: Bool?
        /// Partial-failure explanation when the intended visible appearance
        /// is NOT authoritative after the transaction.
        public var partialFailure: String?

        /// True only when everything the draft requested is now
        /// authoritative (and nothing failed).
        public var succeeded: Bool { partialFailure == nil && editOutcome.succeeded }
    }

    /// Coordinated avatar appearance Save (#7): the full form edit (metadata
    /// section carries the draft's appearance + custom/imageKind semantics)
    /// FIRST with the existing per-key CAS protection, then the staged asset
    /// mutation, then cache reconciliation for the roster refresh.
    ///
    /// Ordering rationale (issue #7 §5): writing shape metadata first
    /// leaves the current image masking it until the clear succeeds —
    /// less visually destructive than clearing first and failing the
    /// metadata write, which would expose the old/default shape.
    ///
    /// Partial failure semantics: a metadata success + asset failure
    /// surfaces an explicit "shape saved but image still active" message
    /// and the caller must keep the editor open — never generic success.
    /// A metadata CAS conflict throws BEFORE any asset mutation (the old
    /// image is never cleared on a conflicted write).
    public func applyAvatarAppearance(
        _ draft: BotAvatarAppearanceDraft,
        edit: BotProfileEdit,
        to bot: FleetBot
    ) async throws -> BotAvatarAppearanceResult {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        // 1. The configure write (metadata + any other carried sections)
        //    with existing CAS discipline — throws typed conflicts on a
        //    stale revision BEFORE any asset mutation. W3 review finding
        //    2: an EMPTY edit (the pure asset-mutation retry after a
        //    partial save — every metadata section already applied)
        //    performs NO configure call at all: re-sending an empty
        //    payload would be a redundant RPC against the already-bumped
        //    revision with nothing to apply.
        let outcome: BotProfileEditOutcome
        if edit.isEmpty {
            outcome = BotProfileEditOutcome()
        } else {
            outcome = try await seam.configureProfile(
                bot.route.profileSlug.rawValue, edit: edit)
        }
        if edit.metadata != nil {
            guard outcome.appliedSections.contains(.metadata) else {
                throw BotSectionSyncError.conflict("The gateway did not apply the appearance metadata")
            }
        }
        editOutcomes[bot.route] = outcome
        editErrors[bot.route] = nil
        // 2. Asset mutation — only after the metadata section applied.
        switch draft.image {
        case .unchanged:
            return BotAvatarAppearanceResult(
                editOutcome: outcome, assetApplied: nil, partialFailure: nil)
        case .remove:
            do {
                try await seam.clearAvatar(bot.route.profileSlug.rawValue)
            } catch {
                await refreshAvatarCaches(for: bot)
                return BotAvatarAppearanceResult(
                    editOutcome: outcome, assetApplied: false,
                    partialFailure: "Shape saved, but the previous image could not be removed. The image is still active. Retry removing it.")
            }
            await refreshAvatarCaches(for: bot)
            return BotAvatarAppearanceResult(
                editOutcome: outcome, assetApplied: true, partialFailure: nil)
        case .replacement(let data):
            // #9 §6: a Pet thumbnail PNG must NEVER route through the JPEG
            // normalization semantics of user-photo uploads — the staged
            // bytes travel as-is, mime-typed by their actual PNG/JPEG
            // signature so pixel edges stay crisp through set_asset.
            let dataURL = BotAvatarAssetCodec.dataURL(forStaged: data)
            do {
                try await seam.uploadAvatar(bot.route.profileSlug.rawValue, dataURL: dataURL)
            } catch {
                await refreshAvatarCaches(for: bot)
                return BotAvatarAppearanceResult(
                    editOutcome: outcome, assetApplied: false,
                    partialFailure: "Metadata saved, but the new image could not be uploaded. Your previous avatar remains active. Retry saving it.")
            }
            await refreshAvatarCaches(for: bot)
            return BotAvatarAppearanceResult(
                editOutcome: outcome, assetApplied: true, partialFailure: nil)
        }
    }

    /// Post-save reconciliation: drop stale avatar caches so the refreshed
    /// roster's hasAvatar is the visible truth, and reseed fetch stamps.
    private func refreshAvatarCaches(for bot: FleetBot) async {
        avatarFetchedAt[bot.route] = nil
        avatarGenerations[bot.route, default: 0] += 1
        avatarDataByRoute[bot.route] = nil
    }

    /// Fetch avatar bytes for a bot (display cache; authoritative flag is
    /// roster hasAvatar). Uses the profiles.get_asset surface.
    public func loadAvatar(for bot: FleetBot) async {
        guard bot.hasAvatar else {
            avatarDataByRoute[bot.route] = nil
            avatarFetchedAt[bot.route] = nil
            return
        }
        guard !avatarLoads.contains(bot.route),
              Date().timeIntervalSince(avatarFetchedAt[bot.route] ?? .distantPast) > 300,
              let seam = seam(for: bot.route.gatewayID) else { return }
        avatarLoads.insert(bot.route)
        if avatarSlots >= 4 {
            await withCheckedContinuation { avatarWaiters.append($0) }
        } else { avatarSlots += 1 }
        defer {
            avatarLoads.remove(bot.route)
            if avatarWaiters.isEmpty { avatarSlots -= 1 }
            else { avatarWaiters.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return }
        avatarFetchedAt[bot.route] = Date()
        let generation = avatarGenerations[bot.route, default: 0]
        if let data = try? await seam.avatarData(bot.route.profileSlug.rawValue),
           !data.isEmpty, data.count <= 2_000_000, avatarGenerations[bot.route, default: 0] == generation {
            avatarDataByRoute[bot.route] = data
        }
    }

    /// Upload an avatar image (data URL) via set_asset ONLY — never ui_meta.
    public func uploadAvatar(_ bot: FleetBot, dataURL: String) async throws {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        try await seam.uploadAvatar(bot.route.profileSlug.rawValue, dataURL: dataURL)
        avatarGenerations[bot.route, default: 0] += 1
        avatarDataByRoute[bot.route] = GatewayBotModeClientBridge.decodeDataURLBytes(dataURL)
    }

    /// Clear the avatar asset ({clear: true}).
    public func clearAvatar(_ bot: FleetBot) async throws {
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        try await seam.clearAvatar(bot.route.profileSlug.rawValue)
        avatarGenerations[bot.route, default: 0] += 1
        avatarDataByRoute[bot.route] = nil
    }

    // MARK: - Pets (#9: route-scoped gallery + thumbnail loading)

    /// Pet picker load phase (two-stage, issue #9): the local phase
    /// (localOnly) is a fast best-effort render; the hydrate phase merges
    /// the full Petdex catalog. State is keyed by full route —
    /// GatewayID + ProfileSlug — never the profile slug alone.
    public enum PetGalleryPhase: Hashable, Sendable {
        /// Content state of a `loaded` gallery (W3 review finding 1): the
        /// local phase is a legitimate rest state when full-catalog
        /// hydration failed — local pets stay visible and the failure is
        /// carried honestly instead of leaving a permanent spinner.
        public enum Hydration: Hashable, Sendable {
            /// The full Petdex catalog merged over the local phase.
            case full
            /// Local/generated pets only (transient between stages).
            case localOnly
            /// Local pets remain visible; the full-catalog hydrate FAILED
            /// (transient, retryable — the sheet surfaces the message with
            /// a retry affordance; the local phase is never discarded).
            case hydrateFailed(String)
        }

        case idle
        case loadingLocal
        case hydrating
        case loaded(Hydration)
        /// Pets are unavailable on this gateway (JSON-RPC
        /// method-not-found) — a capability fact, not a transient failure.
        case unsupported
        /// A load failed with NO content to show; retryable (transient
        /// network/RPC failure).
        case failed(String)
    }

    public private(set) var petGalleryByRoute: [Route: [HermesPet]] = [:]
    public private(set) var petGalleryPhaseByRoute: [Route: PetGalleryPhase] = [:]
    /// Bounded, route-aware thumbnail cache (GatewayID + ProfileSlug +
    /// PetSlug keys — same-slug pets on different routes never share an
    /// entry).
    public let petThumbnailCache = PetThumbnailCache()

    @ObservationIgnored private var petGalleryLoads: Set<Route> = []
    @ObservationIgnored private var petThumbFailed: Set<PetThumbnailCache.Key> = []
    /// In-flight thumbnail fetches keyed by full route provenance (W3
    /// review finding 3): concurrent callers for the same key SHARE the
    /// same underlying request (await the same Task) instead of getting
    /// nil and rendering misleading failure UI. One request per key.
    @ObservationIgnored private var petThumbTasks:
        [PetThumbnailCache.Key: Task<Data?, Never>] = [:]

    /// Pet seam for a route: the Bot's own gateway's profile seam when it
    /// also speaks the Pet surface, else nil (the caller renders the
    /// honest unavailable state — fail closed).
    public func petSeam(for bot: FleetBot) -> (any BotPetManaging)? {
        seam(for: bot.route.gatewayID) as? (any BotPetManaging)
    }

    /// Two-stage gallery load for one bot route (#9): stage 1 loads
    /// installed/generated pets via `pet.gallery {localOnly:true}`
    /// (best-effort — a failure here falls through to the hydrate phase);
    /// stage 2 hydrates the full Petdex catalog and merges. Pet-unavailable
    /// (method-not-found) is sticky; transient failures are retryable.
    public func loadPetGallery(for bot: FleetBot) async {
        let route = bot.route
        guard !petGalleryLoads.contains(route) else { return }
        petGalleryLoads.insert(route)
        defer { petGalleryLoads.remove(route) }
        guard let petSeam = petSeam(for: bot) else {
            petGalleryPhaseByRoute[route] = .unsupported
            return
        }
        // Stage 1 — local/generated pets render fast; errors fall through
        // to the hydrate attempt (the local phase is best-effort).
        petGalleryPhaseByRoute[route] = .loadingLocal
        var local = HermesPetGallery(pets: [])
        do {
            local = try await petSeam.petGallery(
                profile: route.profileSlug.rawValue, localOnly: true)
            if petGalleryLoads.contains(route) {
                petGalleryByRoute[route] = local.pets
                petGalleryPhaseByRoute[route] = .loaded(.localOnly)
            }
        } catch { /* fall through to hydrate */ }
        guard petGalleryLoads.contains(route) else { return }
        // Stage 2 — full Petdex hydration merged over the local phase.
        petGalleryPhaseByRoute[route] = .hydrating
        do {
            let full = try await petSeam.petGallery(
                profile: route.profileSlug.rawValue, localOnly: false)
            let merged = local.merged(with: full)
            petGalleryByRoute[route] = merged.pets
            petGalleryPhaseByRoute[route] = .loaded(.full)
        } catch let error as BotPetError {
            if case .petsUnavailable = error {
                petGalleryByRoute[route] = []
                petGalleryPhaseByRoute[route] = .unsupported
            } else if petGalleryByRoute[route]?.isEmpty != false {
                petGalleryPhaseByRoute[route] = .failed(Redaction.safeErrorDescription(error))
            } else {
                // W3 review finding 1: local pets stay visible and the
                // hydrate failure is honest, transient, and retryable —
                // never a silent permanent spinner over .hydrating.
                petGalleryPhaseByRoute[route] =
                    .loaded(.hydrateFailed(Redaction.safeErrorDescription(error)))
            }
        } catch {
            if petGalleryByRoute[route]?.isEmpty != false {
                petGalleryPhaseByRoute[route] = .failed(Redaction.safeErrorDescription(error))
            } else {
                petGalleryPhaseByRoute[route] =
                    .loaded(.hydrateFailed(Redaction.safeErrorDescription(error)))
            }
        }
    }

    /// Cached-or-fetch PNG thumbnail for one pet cell (W3 review finding
    /// 3): cached success returns immediately; exactly ONE request per
    /// route/profile/pet key is in flight and concurrent callers for the
    /// same key AWAIT the same underlying request; a failed fetch stays
    /// failed until an EXPLICIT retry (so a LazyVGrid scroll or cell
    /// re-materialization never auto-hammers the gateway). Zero remote
    /// writes — `pet.thumb` is read-only.
    public func petThumbnailData(
        for bot: FleetBot, pet: HermesPet
    ) async -> Data? {
        let key = PetThumbnailCache.Key(
            gatewayID: bot.route.gatewayID,
            profileSlug: bot.route.profileSlug,
            petSlug: pet.slug)
        if let cached = petThumbnailCache.pngData(for: key) { return cached }
        // Sticky failure: a previously failed fetch is NOT retried here —
        // only `retryPetThumbnail` clears the failure and re-fetches.
        guard !petThumbFailed.contains(key) else { return nil }
        if let existing = petThumbTasks[key] {
            // Coalescing: share the single in-flight request for this key.
            return await existing.value
        }
        guard let petSeam = petSeam(for: bot) else { return nil }
        let profile = bot.route.profileSlug.rawValue
        let slug = pet.slug
        let sourceURL = pet.thumbnailSourceURL
        let task = Task<Data?, Never> { [petSeam] in
            do {
                return try await petSeam.petThumbnail(
                    profile: profile, slug: slug, sourceURL: sourceURL)
            } catch {
                return nil
            }
        }
        petThumbTasks[key] = task
        let bytes = await task.value
        petThumbTasks[key] = nil
        if let bytes {
            petThumbnailCache.set(bytes, for: key)
            petThumbFailed.remove(key)
        } else {
            petThumbFailed.insert(key)
        }
        return bytes
    }

    /// Reset a failed thumbnail fetch so the cell can retry: clears the
    /// sticky failure FIRST, then performs a fresh fetch through the
    /// normal coalesced path.
    public func retryPetThumbnail(for bot: FleetBot, pet: HermesPet) async {
        let key = PetThumbnailCache.Key(
            gatewayID: bot.route.gatewayID,
            profileSlug: bot.route.profileSlug,
            petSlug: pet.slug)
        petThumbFailed.remove(key)
        _ = await petThumbnailData(for: bot, pet: pet)
    }

    /// Reset a failed gallery load so the sheet can retry (transient).
    public func retryPetGallery(for bot: FleetBot) async {
        let route = bot.route
        petGalleryPhaseByRoute[route] = .idle
        await loadPetGallery(for: bot)
    }

    // MARK: - Duplicate (D11)

    /// Duplicate a bot via supported profile clone: profiles.create
    /// {clone_from} + look copy (shape/color) via metadata; new profile,
    /// own canonical chat, fresh created stamp — the canonical pointer and
    /// created are NEVER copied.
    public func duplicateBot(
        _ bot: FleetBot, occupiedNames: Set<String>
    ) async throws -> String {
        guard let newName = BotDuplicateNaming.candidateName(
            base: bot.route.profileSlug.rawValue, occupiedNames: occupiedNames) else {
            throw BotSectionSyncError.unavailable("No free name for the duplicate")
        }
        guard let seam = seam(for: bot.route.gatewayID) else {
            throw BotSectionSyncError.unavailable("Profile management is unavailable on this gateway")
        }
        // 1. Clone the profile (config/skills/SOUL/memory per clone_from).
        let spec = BotCreateSpec(
            name: newName,
            descriptionText: bot.profileDescription,
            seed: .clone(profile: bot.route.profileSlug.rawValue, cloneAll: true))
        _ = try await seam.createProfile(spec)
        // 2. Copy the LOOK only (shape/color; title gets "(copy)"). `chat`
        //    and `created` are never written — those belong to the original.
        var look = bot.botModeMetadata ?? BotModeMetadata()
        look.sectionID = nil
        let title = bot.botModeMetadata?.title.map { "\($0) (copy)" }
        look.title = title
        let edit = BotProfileEdit(metadata: look)
        _ = try? await seam.configureProfile(newName, edit: edit)
        return newName
    }

    // MARK: - Delete gate (D12)

    /// Honest delete gate for the current gateway generation: the WS
    /// transport has no safe authenticated lifecycle surface — the item is
    /// rendered disabled with its explanation, never a facade.
    public func deleteGate(for gatewayID: GatewayID) -> BotDeleteGate {
        _ = gatewayID
        return BotDeleteGate.currentGatewayGeneration
    }
}

/// Section-registry sync capability (the concrete client conforms; gateways
/// without the ui_meta surface surface an honest unavailable state).
public protocol BotSectionRegistryLoading: Sendable {
    func loadSectionRegistry() async throws -> (sections: [BotSection], revision: Int?)
}

public protocol BotSectionRegistryWriting: Sendable {
    func writeSectionRegistry(value: MetadataValue, expectedRevision: Int?) async throws -> MetadataWriteReceiptLike
}

/// Transport-agnostic write receipt (FleetNetworking's MetadataWriteReceipt
/// conforms app-side).
public struct MetadataWriteReceiptLike: Hashable, Sendable {
    public let applied: Bool
    public let newRevisions: [String: Int]
    public init(applied: Bool, newRevisions: [String: Int]) {
        self.applied = applied
        self.newRevisions = newRevisions
    }
}

/// Typed section-sync failures.
public enum BotSectionSyncError: Error, LocalizedError, Sendable {
    case unsupported(String)
    case unavailable(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .unavailable(let s): return s
        case .conflict(let s): return "Sections were changed by another client — \(s)"
        }
    }
}

/// Tiny bridge for data-URL decoding without importing FleetNetworking.
enum GatewayBotModeClientBridge {
    static func decodeDataURLBytes(_ dataURL: String) -> Data? {
        guard let range = dataURL.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(dataURL[range.upperBound...]))
    }
}

/// Staged avatar asset encoding (#9 §6): staged bytes travel to
/// `profiles.set_asset` unmodified — mime-typed by signature so a Pet
/// thumbnail stays PNG end-to-end (no JPEG recompression; the gateway
/// accepts PNG/JPEG/WebP) while normalized photo uploads remain JPEG.
enum BotAvatarAssetCodec {
    static func dataURL(forStaged data: Data) -> String {
        let mime: String
        if data.count >= 8, data[data.startIndex] == 0x89, data[data.startIndex + 1] == 0x50 {
            mime = "image/png"
        } else if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 {
            mime = "image/jpeg"
        } else {
            mime = "image/png"
        }
        return "data:\(mime);base64," + data.base64EncodedString()
    }
}
