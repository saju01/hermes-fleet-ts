import Foundation
import Observation
import FleetCore

/// Builds a single-gateway connection for a registered gateway, so the app
/// runtime can drive the connect/disconnect/reconnect lifecycle without
/// depending on transport construction itself.
///
/// Mirrors `GatewayConnectionFactory` in FleetNetworking but lives in FleetUI
/// (a different typealias name to avoid cross-module ambiguity) so SwiftUI
/// depends only on the FleetCore seam — never on the transport module (M0
/// hard guard). Injected at the composition root (app target): production
/// builds a `SingleGatewayConnection`; DEBUG simulator builds a scripted
/// connection; tests inject scripted doubles.
public typealias FleetConnectionFactory = @Sendable (
    _ gateway: FleetGateway,
    _ credential: GatewayCredential?
) -> any GatewayConnectivityProviding

/// Builds a per-gateway conversation session (U3): connectivity + conversation
/// + replay + history over one transport. Mirrors `FleetConnectionFactory` but
/// lives in FleetUI so SwiftUI depends only on the FleetCore seam — never on
/// the transport module (M0 hard guard). Injected at the composition root:
/// production builds a `GatewayConversationSession`; DEBUG builds a scripted
/// session; tests inject scripted doubles.
public typealias FleetConversationFactory = @Sendable (
    _ gateway: FleetGateway,
    _ credential: GatewayCredential?
) -> any ConversationSessionProviding

/// Builds a per-gateway kanban board watcher (t_3b321b7b). Lives in FleetUI
/// for the same M0-guard reason as the factories above: SwiftUI depends only
/// on the FleetCore `KanbanBoardWatching` seam — never on the transport
/// module. Injected at the composition root: production builds a
/// `KanbanEventStreamClient`; DEBUG builds a scripted watcher; tests inject
/// doubles.
public typealias FleetKanbanWatcherFactory = @Sendable (
    _ gateway: FleetGateway
) -> any KanbanBoardWatching

/// Builds a per-gateway management seam (R9-T5/T6 — cron + skills). Lives in
/// FleetUI for the same M0-guard reason as the factories above: SwiftUI
/// depends only on the FleetCore `GatewayManagementProviding` seam — never on
/// the transport module. Injected at the composition root: production builds
/// a `GatewayManagementClient` over the gateway's transport; DEBUG builds a
/// scripted seam; tests inject doubles.
public typealias FleetManagementSeamFactory = @Sendable (
    _ gateway: FleetGateway
) -> any GatewayManagementProviding

/// Builds a per-gateway learning seam (R9-T7 — memory graph). Same M0-guard
/// construction as the management seam above.
public typealias FleetLearningSeamFactory = @Sendable (
    _ gateway: FleetGateway
) -> any GatewayLearningProviding

/// Builds a per-gateway projects seam (R10-T3 — remote file browser).
/// Same M0-guard construction as the seams above.
public typealias FleetProjectsSeamFactory = @Sendable (
    _ gateway: FleetGateway
) -> any GatewayProjectsProviding

/// True Bots Mode — builds a per-gateway Bot Mode chat seam (canonical
/// "Bot Chat" lookup + safe creation). Same M0-guard construction as the
/// seams above: SwiftUI depends only on the FleetCore
/// `BotModeChatProviding` seam — never on the transport module.
public typealias FleetBotModeChatFactory = @Sendable (
    _ gateway: FleetGateway
) -> any BotModeChatProviding

/// True Bots Mode slice 2 — builds a per-gateway bot profile management
/// seam (describe/configure/create/avatar/ui-meta key writes).
public typealias FleetBotProfileFactory = @Sendable (
    _ gateway: FleetGateway
) -> any BotProfileManaging

/// True Bots Mode slice 2 — builds a per-gateway room source (hosted +
/// desktop-legacy providers unioned app-side).
public typealias FleetRoomSourceFactory = @Sendable (
    _ gateway: FleetGateway
) -> any FleetRoomSourceProviding

/// R10-T4 — builds the on-device voice engine (Speech framework STT +
/// AVSpeechSynthesizer TTS) shared by every conversation view model. nil ⇒
/// the fail-closed `UnsupportedVoiceTranscriber` (mic affordances hidden).
/// Lives in FleetUI for the same M0-guard reason as the factories above:
/// SwiftUI depends only on the FleetCore `VoiceTranscribing` seam — never on
/// AVFoundation/Speech directly.
public typealias FleetVoiceEngineFactory = @Sendable () -> (any VoiceTranscribing)?

/// Injected invalidation hooks keep FleetUI independent of FleetNetworking's
/// ephemeral session store while ensuring credential/configuration changes
/// cannot retain an authenticated lease for old gateway state.
public typealias FleetGatewaySessionInvalidator = @Sendable (_ gatewayID: GatewayID) async -> Void
public typealias FleetGatewaySessionInvalidatorAll = @Sendable () async -> Void

/// Observable, per-gateway connection lifecycle (spec §13 states; §31
/// "disconnect does not crash").
///
/// U1: the runtime owns the lifecycle — connect / disconnect / reconnect are
/// driven here and their phases are `@Observable` so SwiftUI renders
/// Connecting / Connected / Offline / failed-state transitions without
/// importing the transport module.
public enum GatewayConnectionState: Equatable, Sendable {
    /// Never connected this session (fresh registry entry).
    case idle
    /// `connect()` in flight (socket handshake / `gateway.ready` wait).
    case connecting
    /// Fully connected and serving (status online/degraded).
    case connected
    /// Cleanly disconnected (client requested teardown; status offline).
    case disconnected
    /// A connect attempt failed. `status` is the classified §13 status
    /// (authRequired / offline / unsupported / degraded) — never a guess.
    case failed(GatewayStatus)

    /// Map a transport seam status onto the observable lifecycle vocabulary.
    init(status: GatewayStatus) {
        switch status {
        case .online, .degraded: self = .connected
        case .connecting: self = .connecting
        case .offline, .authenticationRequired, .unsupported: self = .failed(status)
        }
    }
}

/// The observable application runtime for the Hermes Fleet cockpit.
///
/// U1 composition (all behind FleetCore seams — NO FleetNetworking import in
/// FleetUI):
/// - `any GatewayRegistryManaging` — gateway registry CRUD + credentials +
///   testConnection (concrete `GatewayRegistryService` injected at root).
/// - `any FleetRosterProviding` — the M8 multi-gateway union roster (concrete
///   `FleetRosterService` injected at root).
/// - `any CacheStoring` — the M10 non-secret persistence cache (concrete
///   `SwiftDataCacheStore` injected at root).
/// - `FleetConnectionFactory` — per-gateway connection lifecycle seam.
///
/// The app owns the connection lifecycle: `connect` / `disconnect` /
/// `reconnect` transition `connectionStates[id]` which SwiftUI observes.
@MainActor
@Observable
public final class AppEnvironment {
    public let embeddedTailnet: (any EmbeddedTailnetManaging)?
    // MARK: Observable state (SwiftUI reads these)

    /// Registered gateways in stable ID order.
    public private(set) var gateways: [FleetGateway] = []
    /// Latest union-roster snapshot (nil until the first refresh).
    public private(set) var rosterSnapshot: FleetRosterSnapshot?
    /// True while a roster refresh is in flight.
    public private(set) var isRefreshing = false
    /// Count of cached session watermarks (proves the cache seam is wired;
    /// non-secret — synthesis §12).
    public private(set) var cachedWatermarkCount = 0
    /// Per-gateway connection lifecycle, observable.
    public private(set) var connectionStates: [GatewayID: GatewayConnectionState] = [:]

    /// H2: latest per-gateway connection-health snapshots (uptime %,
    /// reconnects, last-disconnect reason, ping RTT). Updated by
    /// `refreshHealthStats()`; the Health dashboard refreshes it live.
    public private(set) var healthStats: [GatewayID: GatewayHealthStats] = [:]

    /// P0-2: in-progress Add/Edit-Gateway form draft. Lives HERE (composition
    /// root) so it survives the H1 biometric lock / scenePhase teardown — the
    /// form sheet is destroyed on background+relock, and `GatewaysView`
    /// re-presents it from this store on unlock. In-memory only, never
    /// persisted.
    public let gatewayFormDraft = GatewayFormDraftStore()

    /// Per-gateway connection-test result, observable (§13 reachable /
    /// unreachable probe). Set only after `testConnection` completes; a
    /// gateway with no entry has never been tested this session.
    public private(set) var testResults: [GatewayID: GatewayTestResult] = [:]
    public private(set) var testResultObservedAt: [GatewayID: Date] = [:]

    /// Gateways currently running a connection test (for a Testing… row).
    public private(set) var testingGatewayIDs: Set<GatewayID> = []

    /// Sessions per bot route, fetched via the read-only `session.list` seam.
    /// Observable so Bot detail re-renders as a fetch resolves.
    public private(set) var sessionsByRoute: [Route: [SessionSummary]] = [:]

    /// Routes whose `session.list` fetch is in flight.
    public private(set) var loadingRoutes: Set<Route> = []

    /// True Bots Mode: pending navigation request — a screen push that
    /// originates outside the view tree (the canonical Bot Chat open).
    /// FleetTabView observes this and appends it to the active tab's path.
    public internal(set) var pendingBotChatNavigation: FleetScreen?
    /// FOS-5: one-shot screen push request (consumed by the shell).
    public internal(set) var pendingScreenNavigation: FleetScreen?

    /// True Bots Mode slice 2: bot profile management (create/edit/duplicate/
    /// avatar/sections) over the per-gateway seam.
    public let botManagement: BotManagementController

    /// FOS-4 (SPEC §7 Continue / §17): device-local recent-open index.
    /// Records opens ONLY after a real destination resolved; ≤50 refs,
    /// 30-day retention, pruned when a gateway is removed. No secrets.
    public private(set) var continueIndex: FleetContinueIndexStore

    /// FOS-4 (SPEC §7 Needs You): attention items observed from OPENED
    /// rooms (driver pending approvals/retries/blocked) — keyed by gateway,
    /// replaced by each fresh observation of that room. Home renders these
    /// WITHOUT any groups.state fan-out: only what this phone already read.
    public private(set) var observedRoomAttention: [GatewayID: [FleetAttentionItem]] = [:]

    /// FOS-4 (SPEC §7 freshness): when the current roster snapshot settled.
    /// Anchors "Last checked …" labels (the snapshot itself is timeless).
    public private(set) var rosterObservedAt: Date?

    /// FOS-4 (SPEC §17): the ONE summary scheduler (app seam — never a row
    /// view). Foreground cadence 30s/gateway, failure backoff 30/60/120/300,
    /// coalesced refreshes; observation happens only on explicit triggers
    /// (Home entry / pull-to-refresh), never on a timer.
    private let summaryScheduler = FleetSummaryScheduler()
    @ObservationIgnored private var summarySourceStates: [GatewayID: FleetSummaryScheduler.SourceState] = [:]
    @ObservationIgnored private var summaryRefreshInFlight = false

    /// App-launch hydration is shared by the initial authentication task and
    /// the post-passcode-unlock path. Marking this before the awaits prevents
    /// those paths from restoring the registry or refreshing the roster twice
    /// when automatic authentication succeeds.
    @ObservationIgnored private var didHydrateEnvironment = false

    /// First-run gate (hydration model): the root shell distinguishes
    /// "registry not loaded yet" from "loaded and empty" so a brand-new user
    /// lands on setup BEFORE the normal tab UI, without a fragile
    /// hasSeenOnboarding flag. The authoritative state is the hydrated
    /// gateway registry itself: `.loading` until the first `load()` settles,
    /// then `.unconfigured` (zero gateways) or `.configured` (≥1). Removing
    /// the final gateway flips back to `.unconfigured` — returning to setup
    /// is the intended product behavior. In-process only; the registry
    /// (SwiftData records) remains the durable truth.
    public enum HydrationPhase: Equatable, Sendable {
        case loading
        case unconfigured
        case configured
    }

    /// Current first-run phase. Observable so the root shell can gate the
    /// whole UI on it (see FleetTabView).
    public private(set) var hydrationPhase: HydrationPhase = .loading

    /// Recompute the first-run phase from the hydrated registry. Called at
    /// the end of every `load()`/`reloadGateways()` settlement so the phase
    /// always reflects reality (add → configured; remove-the-last →
    /// unconfigured).
    private func settleHydrationPhase() {
        hydrationPhase = gateways.isEmpty ? .unconfigured : .configured
    }

    /// Bots per gateway from the last SUCCESSFUL refresh — the offline-ghost
    /// cache (a failed refresh renders these dimmed, identity retained).
    public private(set) var cachedBotsByGateway: [GatewayID: [FleetBot]] = [:]

    /// Room rows per gateway (hosted + desktop legacy) from the room-source
    /// seam; empty until first load, honest absence otherwise.
    public private(set) var roomsByGateway: [GatewayID: [FleetRoom]] = [:]

    /// F1: last-known GATEWAY-level `groups.create` capability (from the
    /// room source's `groups.capabilities` probe, persisted across
    /// refreshes — a transport hiccup must not hide the Create Room entry
    /// on a capable gateway). Absent = never probed = fail closed.
    public private(set) var canCreateRoomsByGateway: [GatewayID: Bool] = [:]

    /// True Bots Mode: request navigation to the canonical Bot Chat screen.
    /// Called by `BotChatOpenButton` after a successful fail-closed resolve.
    public func openBotChat(route: Route, sessionID: String) {
        pendingBotChatNavigation = .conversation(route, sessionID: sessionID, canonical: true)
        canonicalOpenIDs[route] = sessionID
    }

    /// FOS-5 (SPEC §10 Compose): request a screen push from anywhere in the
    /// app (sheet-origin navigation that cannot embed a NavigationLink). The
    /// shell observes this and opens the destination on the OWNING tab.
    public func requestScreen(_ screen: FleetScreen) {
        pendingScreenNavigation = screen
    }

    /// D03: whether (route, sessionID) is the canonical "Bot Chat" for the
    /// bot — either the roster-reported canonical session (id or compression
    /// tip) or a session this environment opened through the canonical path.
    /// Drives the exact "Bot Chat" screen title (identity, not decoration).
    public func isCanonicalBotChat(route: Route, sessionID: String) -> Bool {
        if canonicalOpenIDs[route] == sessionID { return true }
        guard let bot = rosterSnapshot?.bot(for: route) else { return false }
        guard let canonical = bot.canonicalSession else { return false }
        return canonical.id == sessionID || canonical.resolvedID == sessionID
    }

    /// Sessions this environment opened through the canonical path.
    @ObservationIgnored private var canonicalOpenIDs: [Route: String] = [:]

    /// Last classified read error per route (non-secret), for the Bot-detail
    /// error state. Absent until a fetch fails.
    public private(set) var sessionReadErrors: [Route: String] = [:]

    /// When each route's sessions were last successfully observed. This is
    /// in-process freshness metadata only; a failed read never stamps a
    /// route fresh and never removes its cached sessions.
    @ObservationIgnored private var sessionsObservedAt: [Route: Date] = [:]
    @ObservationIgnored private var sessionReadGenerations: [Route: Int] = [:]

    /// Chats session-list freshness window.
    public static let sessionFreshnessTTL: TimeInterval = 30

    // MARK: Injected seams (composition root)

    private let registry: any GatewayRegistryManaging
    private let roster: any FleetRosterProviding
    private let cache: any CacheStoring
    /// Optional production TLS trust stores. Scripted/test environments do
    /// not need the UI re-pair surface and leave these nil.
    private let tlsPinStore: (any TLSPinStoring)?
    private let tlsApprovalStore: (any TLSFirstUseApprovalStoring)?
    private let connectionFactory: FleetConnectionFactory
    /// H2: connection-health accumulator (FleetCore seam; concrete
    /// `GatewayHealthStatsAccumulator` fed by the composition root's transport
    /// feed task — FleetUI never touches the transport module).
    private let health: any ConnectionHealthAccumulating
    /// Read-only `session.list` path for Bot detail (injected concrete:
    /// `GatewaySessionListService` in production, scripted in DEBUG/tests).
    private let sessionList: any SessionListProviding
    /// R9-T1: biometric seam for the approval gate (FaceID-gated approve /
    /// confirmed YOLO enable). Injected by the app composition root; the
    /// default fails closed.
    private let biometrics: any AppLockBiometricAuth
    /// U3 conversation sessions per gateway (injected concrete:
    /// `GatewayConversationSession` in production, scripted in DEBUG/tests).
    private let conversationFactory: FleetConversationFactory?
    /// t_3b321b7b: kanban board watcher factory — one watcher per gateway
    /// (the concrete `KanbanEventStreamClient` in production, scripted in
    /// DEBUG/tests).
    private let kanbanWatcherFactory: FleetKanbanWatcherFactory?
    /// R9-T5/T6: management seam factory (cron + skills) — one per gateway
    /// (the concrete `GatewayManagementClient` in production, scripted in
    /// DEBUG/tests).
    private let managementSeamFactory: FleetManagementSeamFactory?
    /// True Bots Mode: per-gateway canonical-chat seam factory (the concrete
    /// `GatewayBotModeClient` in production, scripted in DEBUG/tests).
    private let botModeChatFactory: FleetBotModeChatFactory?
    /// Cached per-gateway Bot Mode chat seams (mirrors managementSeams).
    @ObservationIgnored private var botModeChatSeams: [GatewayID: any BotModeChatProviding] = [:]
    /// Slice 2: room-source factory (app-side union provider).
    private let roomSourceFactory: FleetRoomSourceFactory?
    @ObservationIgnored private var roomSources: [GatewayID: any FleetRoomSourceProviding] = [:]
    /// Slice 4: room-chat command seam factory (app-side `groups.*`
    /// adapter; scripted in DEBUG/tests).
    private let roomCommandFactory: FleetRoomCommandFactory?
    @ObservationIgnored private var roomCommands: [GatewayID: any RoomChatCommanding] = [:]
    /// Slice 4: driver-status seam factory (groups.state driver_status).
    private let roomDriverStatusFactory: FleetRoomDriverStatusFactory?
    @ObservationIgnored private var roomDriverStatuses: [GatewayID: any RoomDriverStatusProviding] = [:]
    /// Slice 5 (D19): RoomLink command seam factory (app-side
    /// `GatewayRoomLinkClient` adapter; scripted in DEBUG/tests).
    private let roomLinkFactory: FleetRoomLinkFactory?
    @ObservationIgnored private var roomLinks: [GatewayID: any RoomLinkCommanding] = [:]
    /// R9-T7: learning seam factory (memory graph) — one per gateway (the
    /// concrete `GatewayLearningClient` in production, scripted in
    /// DEBUG/tests).
    private let learningSeamFactory: FleetLearningSeamFactory?
    /// R9-T7: learning-graph snapshot store (offline browse). Optional —
    /// tests inject doubles; production passes the composition root's
    /// SwiftData cache store adapted to the FleetCore seam.
    private let learningSnapshotStore_: (any LearningGraphSnapshotStoring)?
    /// R10-T3: projects seam factory (remote file browser) — one per
    /// gateway (the concrete `GatewayProjectsClient` in production,
    /// scripted in DEBUG/tests).
    private let projectsSeamFactory: FleetProjectsSeamFactory?

    /// R10-T4 — builds the shared on-device voice engine (nil ⇒ fail-closed
    /// default; mic affordances hidden).
    private let voiceEngineFactory: FleetVoiceEngineFactory?
    /// R10-T3: projects-tree snapshot store (offline browse). Same
    /// construction as the learning snapshot store.
    private let projectsSnapshotStore_: (any ProjectsSnapshotStoring)?
    /// Gateways to register on first launch (empty registry) so the U1
    /// navigation skeleton is walkable in the simulator. Presentation data
    /// only — the user manages the real fleet in U2.
    private let seedRegistrations: [GatewayRegistration]

    /// Active connection per gateway (owned by the runtime; survives view
    /// teardowns so disconnect/reconnect are stable).
    private var activeConnections: [GatewayID: any GatewayConnectivityProviding] = [:]

    /// Desired connection intent is deliberately distinct from live transport
    /// state. The store contains gateway IDs only; production backs it with
    /// UserDefaults and tests/simulator may keep it in-process.
    private let connectionIntent: ConnectionIntentStore
    private let gatewaySessionInvalidator: FleetGatewaySessionInvalidator?
    private let gatewaySessionInvalidatorAll: FleetGatewaySessionInvalidatorAll?

    /// Lazily-built U3 conversation sessions per gateway (one per gateway;
    /// created on first conversation screen use).
    private var conversationSessions: [GatewayID: any ConversationSessionProviding] = [:]

    /// Long-lived Kanban event watchers, retained by the runtime so a
    /// background/lock boundary can stop their reconnect pumps even when the
    /// board view itself remains mounted. The concrete watcher is restartable
    /// when a board view is opened again.
    @ObservationIgnored private var kanbanWatchers: [GatewayID: any KanbanBoardWatching] = [:]

    /// R9-T5/T6: lazily-built management seams per gateway (one per
    /// gateway; created on first Cron/Skills pane use — the pane's
    /// transport survives view teardowns like a conversation session's).
    private var managementSeams: [GatewayID: any GatewayManagementProviding] = [:]

    /// R9-T7: lazily-built learning seams per gateway (same lifetime as
    /// the management seams).
    private var learningSeams: [GatewayID: any GatewayLearningProviding] = [:]

    /// R10-T3: lazily-built projects seams per gateway (same lifetime as
    /// the learning seams).
    private var projectsSeams: [GatewayID: any GatewayProjectsProviding] = [:]

    /// Generation of the newest roster refresh (t_e77c614c). Bumped each time
    /// `refreshRoster()` starts; an in-flight refresh whose captured token no
    /// longer matches is STALE and must not settle observable state (the
    /// `OnboardingViewModel.beginOperation()` fencing pattern).
    @ObservationIgnored private var rosterGeneration = 0

    /// A successful connection repairs the roster source, but its probe may
    /// race an already-running refresh. Coalesce that repair into one
    /// trailing observation instead of starting a refresh storm.
    @ObservationIgnored private var needsPostConnectRosterSync = false
    @ObservationIgnored private var postConnectSyncQueued = false

    public init(
        registry: any GatewayRegistryManaging,
        roster: any FleetRosterProviding,
        cache: any CacheStoring,
        tlsPinStore: (any TLSPinStoring)? = nil,
        tlsApprovalStore: (any TLSFirstUseApprovalStoring)? = nil,
        sessionList: any SessionListProviding,
        connectionFactory: @escaping FleetConnectionFactory,
        conversationFactory: FleetConversationFactory? = nil,
        kanbanWatcherFactory: FleetKanbanWatcherFactory? = nil,
        managementSeamFactory: FleetManagementSeamFactory? = nil,
        learningSeamFactory: FleetLearningSeamFactory? = nil,
        learningSnapshotStore: (any LearningGraphSnapshotStoring)? = nil,
        projectsSeamFactory: FleetProjectsSeamFactory? = nil,
        projectsSnapshotStore: (any ProjectsSnapshotStoring)? = nil,
        botModeChatFactory: FleetBotModeChatFactory? = nil,
        botProfileFactory: FleetBotProfileFactory? = nil,
        roomSourceFactory: FleetRoomSourceFactory? = nil,
        roomCommandFactory: FleetRoomCommandFactory? = nil,
        roomDriverStatusFactory: FleetRoomDriverStatusFactory? = nil,
        roomLinkFactory: FleetRoomLinkFactory? = nil,
        health: any ConnectionHealthAccumulating,
        biometrics: any AppLockBiometricAuth = NeverLockBiometricAuth(),
        seedRegistrations: [GatewayRegistration] = [],
        voiceEngineFactory: FleetVoiceEngineFactory? = nil,
        connectionIntentDefaults: UserDefaults? = nil,
        gatewaySessionInvalidator: FleetGatewaySessionInvalidator? = nil,
        gatewaySessionInvalidatorAll: FleetGatewaySessionInvalidatorAll? = nil,
        embeddedTailnet: (any EmbeddedTailnetManaging)? = nil
    ) {
        self.registry = registry
        self.embeddedTailnet = embeddedTailnet
        self.roster = roster
        self.cache = cache
        self.tlsPinStore = tlsPinStore
        self.tlsApprovalStore = tlsApprovalStore
        self.sessionList = sessionList
        self.connectionFactory = connectionFactory
        self.conversationFactory = conversationFactory
        self.kanbanWatcherFactory = kanbanWatcherFactory
        self.managementSeamFactory = managementSeamFactory
        self.learningSeamFactory = learningSeamFactory
        self.learningSnapshotStore_ = learningSnapshotStore
        self.projectsSeamFactory = projectsSeamFactory
        self.projectsSnapshotStore_ = projectsSnapshotStore
        self.botModeChatFactory = botModeChatFactory
        self.health = health
        self.biometrics = biometrics
        self.seedRegistrations = seedRegistrations
        self.voiceEngineFactory = voiceEngineFactory
        self.connectionIntent = ConnectionIntentStore(defaults: connectionIntentDefaults)
        self.gatewaySessionInvalidator = gatewaySessionInvalidator
        self.gatewaySessionInvalidatorAll = gatewaySessionInvalidatorAll
        self.roomSourceFactory = roomSourceFactory
        self.roomCommandFactory = roomCommandFactory
        self.roomDriverStatusFactory = roomDriverStatusFactory
        self.roomLinkFactory = roomLinkFactory
        // FOS-4: the device-local recent-open index. Tests inject a temp-file
        // store via `attachContinueIndex(_:)`; production uses the default
        // Application Support location. (Assigned BEFORE any self capture.)
        self.continueIndex = FleetContinueIndexStore(url: FleetContinueIndexStore.defaultURL())
        self.botManagement = BotManagementController(factory: botProfileFactory)
        botManagement.setGatewayProvider { [weak self] in self?.gateways ?? [] }
    }

    /// FOS-4: swap the Continue index store (tests inject a hermetic one).
    public func attachContinueIndex(_ store: FleetContinueIndexStore) {
        continueIndex = store
    }

    // MARK: Load / refresh

    /// Load gateways from the registry. On a truly empty registry, seeds the
    /// known gateways (DEBUG simulator walkthrough) — never overrides a
    /// user-managed fleet.
    public func load() async {
        // P0-4: FIRST rebuild the registry from the durable record store so a
        // user-added gateway survives app close / relaunch (never-connected
        /// entries included, restored disconnected). Restore runs BEFORE the
        /// seeding check so a restored user fleet suppresses seeding.
        do {
            _ = try await registry.restorePersistedGateways()
        } catch {
            // A broken record store must not brick launch — log and continue
            // with the (possibly empty) in-memory registry.
            #if DEBUG
            print("P0-4 gateway restore failed: \(error)")
            #endif
        }
        let existing = await registry.allGateways()
        if existing.isEmpty, !seedRegistrations.isEmpty {
            for registration in seedRegistrations {
                try? await registry.addGateway(registration)
            }
        }
        await reloadGateways()
        cachedWatermarkCount = (try? await cache.loadWatermarks())?.count ?? 0
        // First-run gate: load() has settled — the registry's emptiness (or
        // not) is now authoritative, so the root shell may leave .loading.
        settleHydrationPhase()
    }

    /// Hydrate protected app content exactly once per runtime instance.
    ///
    /// The composition root calls this only after App Lock authentication has
    /// completed. Keeping the guard here makes the initial-authentication and
    /// passcode-fallback paths idempotent even though each is launched from a
    /// separate SwiftUI task.
    public func hydrateIfNeeded() async {
        guard !didHydrateEnvironment else { return }
        didHydrateEnvironment = true
        await load()
        await refreshRoster()
        await restoreIntendedConnections()
    }

    private func reloadGateways() async {
        gateways = await registry.allGateways()
        connectionIntent.prune(to: Set(gateways.map(\.id)))
        for gateway in gateways where connectionStates[gateway.id] == nil {
            connectionStates[gateway.id] = .idle
        }
        // H2: restore persisted health stats for any registered gateway the
        // accumulator has not observed this session (e.g. a gateway re-added
        // after an app restart — the registry is in-memory, the health store
        // is not). Live entries are untouched by the accumulator's guard.
        await health.rehydrate(gatewayIDs: gateways.map(\.id))
        healthStats = await health.snapshot()
        // First-run gate: keep the phase honest on every registry settlement
        // (add-gateway → configured; remove-the-last → unconfigured).
        settleHydrationPhase()
    }

    /// Begins a tracked roster refresh and returns its generation token used
    /// to fence settlement against newer overlapping refreshes (the
    /// `OnboardingViewModel.beginOperation()` reference pattern).
    private func beginRosterRefresh() -> Int {
        rosterGeneration += 1
        return rosterGeneration
    }

    /// Refresh the union fleet roster (M8). Never throws for a single-gateway
    /// outage (partial-availability contract).
    ///
    /// t_e77c614c: generation-fenced — a rapid retap starts a newer refresh
    /// whose token supersedes any still-in-flight older one; the stale
    /// completion is silently dropped so observable state always reflects
    /// only the most recent refresh.
    public func refreshRoster() async {
        // A refresh beginning now probes every registered gateway. Clear the
        // pending repair before awaiting so a connect that lands during this
        // wave can re-arm the trailing refresh below.
        needsPostConnectRosterSync = false
        let token = beginRosterRefresh()
        isRefreshing = true
        let previousOutcomes = rosterSnapshot?.gatewayOutcomes ?? [:]
        let snapshot = await roster.refreshRoster()
        // Stale completion: a newer refresh owns settlement — silently drop
        // the result (observable state stays what the newest refresh set).
        guard token == rosterGeneration else { return }
        rosterSnapshot = snapshot
        rosterObservedAt = Date()
        isRefreshing = false
        // FOS-4 (SPEC §17): settle the per-gateway scheduler bookkeeping —
        // success resets the backoff ladder; a classified failure climbs it.
        for gateway in gateways {
            let state = summarySourceStates[gateway.id] ?? .empty
            switch snapshot.outcome(for: gateway.id) {
            case .loaded:
                summarySourceStates[gateway.id] = summaryScheduler.onSuccess(state)
            case .failed:
                summarySourceStates[gateway.id] = summaryScheduler.onFailure(state)
            case nil:
                // The refresh settled without classifying this gateway —
                // an uncovered observation counts as a failure for backoff
                // (it must not be re-driven immediately).
                summarySourceStates[gateway.id] = summaryScheduler.onFailure(state)
            }
        }
        // Slice 2: cache each SUCCESSFUL gateway's bots for offline-ghost
        // rendering on later failed refreshes (identity retained).
        // FOS-5 (SPEC §9): a SUCCESSFUL refresh that reports ZERO bots clears
        // that gateway's ghost cache — a failing-to-clear cache would
        // resurrect deleted bots on a later outage. Empty is authoritative
        // when the gateway answered.
        for gateway in snapshot.roster.allGateways {
            if case .loaded = snapshot.outcome(for: gateway.id) {
                // A recovered gateway may have changed session state while it
                // was unreachable. Invalidate only that gateway's cached
                // observations; unrelated gateways remain fresh.
                if case .failed = previousOutcomes[gateway.id] {
                    invalidateSessions(on: gateway.id)
                }
                let bots = snapshot.bots(on: gateway.id)
                if !bots.isEmpty {
                    cachedBotsByGateway[gateway.id] = bots
                } else {
                    cachedBotsByGateway[gateway.id] = nil
                }
            }
        }
        // Slice 2: best-effort room + section-registry sync after roster
        // refresh (observational, never blocks the roster).
        await loadRooms()
        await loadAllSections()

        if needsPostConnectRosterSync {
            needsPostConnectRosterSync = false
            queuePostConnectRosterSync()
        }
    }

    /// Re-observe the authoritative roster after a gateway transport repair.
    /// Presence still comes only from a successful `profiles.list` outcome;
    /// connection state alone never fabricates an online bot.
    private func scheduleRosterSyncAfterConnectionRepair(for id: GatewayID) {
        // Reset the documented per-gateway summary backoff after an explicit
        // connection repair so the next Bots/Home observation is due now.
        summarySourceStates[id] = nil
        if isRefreshing {
            needsPostConnectRosterSync = true
        } else {
            queuePostConnectRosterSync()
        }
    }

    private func queuePostConnectRosterSync() {
        guard !postConnectSyncQueued else { return }
        postConnectSyncQueued = true
        Task {
            postConnectSyncQueued = false
            await refreshRoster()
        }
    }

    // MARK: FOS-4 — bounded Home summary observation (SPEC §17)

    /// Whether ANY registered gateway is due for its bounded summary
    /// observation right now (30s foreground cadence / failure backoff).
    public func summaryObservationDue() -> Bool {
        gateways.contains { summaryScheduler.isDue(summarySourceStates[$0.id] ?? .empty) }
    }

    /// Home-entry / pull-to-refresh observation: triggers at most ONE
    /// roster refresh when any gateway is due; a second pull joins the
    /// in-flight cycle instead of stacking another wave (coalesced). The
    /// wave itself is bounded by the roster service (≤3 gateways in flight,
    /// 10s per-gateway deadline).
    public func refreshSummaryIfDue() async {
        guard summaryObservationDue(), !summaryRefreshInFlight else { return }
        summaryRefreshInFlight = true
        defer { summaryRefreshInFlight = false }
        await refreshRoster()
    }

    /// FOS-4 (SPEC §7 Needs You): publish observations from an OPENED room's
    /// driver status into the known-items aggregator (freshness = now).
    /// Called by RoomChatView's existing scoped read — Home NEVER fans out
    /// groups.state on its own; it renders only these published items.
    public func publishRoomAttention(
        room: FleetRoom,
        status: RoomDriverStatus?,
        observedAt: Date = Date()
    ) {
        var items: [FleetAttentionItem] = []
        if let status {
            for approval in status.pendingApprovals {
                items.append(FleetAttentionItem(
                    id: "room-approval|\(room.id.gatewayID.rawValue)|\(room.id.key)|\(approval.id)",
                    kind: .roomApproval,
                    gatewayID: room.id.gatewayID,
                    title: "Review \(room.name)",
                    detail: approval.approval["prompt"]?.stringValue
                        ?? approval.approval["summary"]?.stringValue,
                    observedAt: observedAt,
                    destination: .room(room.id)))
            }
            for retry in status.pendingRetries {
                items.append(FleetAttentionItem(
                    id: "room-retry|\(room.id.gatewayID.rawValue)|\(room.id.key)|\(retry.taskID)",
                    kind: .roomRetry,
                    gatewayID: room.id.gatewayID,
                    title: "Retry \(room.name)",
                    detail: "A turn failed and is waiting",
                    observedAt: observedAt,
                    destination: .room(room.id)))
            }
            if status.blocked {
                items.append(FleetAttentionItem(
                    id: "room-blocked|\(room.id.gatewayID.rawValue)|\(room.id.key)",
                    kind: .roomDriverBlocked,
                    gatewayID: room.id.gatewayID,
                    title: "Review blocked Group",
                    detail: room.name,
                    observedAt: observedAt,
                    destination: .room(room.id)))
            }
        }
        // Replace this gateway's published set: a fresh observation of the
        // same room supersedes its earlier items (same request/generation
        // ids dedupe naturally; cleared pendings drop out).
        var perGateway = observedRoomAttention[room.id.gatewayID] ?? []
        let roomPrefix = "room-approval|\(room.id.gatewayID.rawValue)|\(room.id.key)|",
            retryPrefix = "room-retry|\(room.id.gatewayID.rawValue)|\(room.id.key)|",
            blockedPrefix = "room-blocked|\(room.id.gatewayID.rawValue)|\(room.id.key)"
        perGateway.removeAll {
            $0.id.hasPrefix(roomPrefix) || $0.id.hasPrefix(retryPrefix) || $0.id == blockedPrefix
        }
        perGateway.append(contentsOf: items)
        observedRoomAttention[room.id.gatewayID] = perGateway
    }

    /// FOS-4: the aggregated Needs You items (gateway-classified live
    /// failures + already-observed room items), priority-sorted.
    public func attentionItems() -> [FleetAttentionItem] {
        var items = FleetAttentionProjection.gatewayItems(
            gateways: gateways, snapshot: rosterSnapshot)
        for (_, roomItems) in observedRoomAttention {
            items.append(contentsOf: roomItems)
        }
        return items.sorted(by: FleetAttentionItem.prioritySort)
    }

    /// FOS-4: Needs You coverage truth — complete only when every gateway
    /// is classified AND no room was ever observed (room summaries are
    /// per-room; a complete inbox needs class-C gateway support).
    public func attentionCoverage() -> FleetAttentionCoverage {
        let coverage = FleetAttentionCoverage.compute(gateways: gateways, snapshot: rosterSnapshot)
        if !observedRoomAttention.values.allSatisfy({ $0.isEmpty }) {
            return FleetAttentionCoverage(allGatewaysClassified: false)
        }
        return coverage
    }

    /// Slice 2: rooms per gateway from the room-source seam (best-effort;
    /// failures leave previous state — honest absence, no fabricated rows).
    public func loadRooms() async {
        guard let roomSourceFactory else { return }
        for gateway in gateways {
            let source: any FleetRoomSourceProviding
            if let existing = roomSources[gateway.id] {
                source = existing
            } else {
                source = roomSourceFactory(gateway)
                roomSources[gateway.id] = source
            }
            let rooms = await source.rooms()
            roomsByGateway[gateway.id] = rooms
            // F1: persist the GATEWAY-level create capability — zero-room
            // capable gateways must keep the Create Room entry; `.unknown`
            // (probe failure) never flips the gate either way, and a
            // definitive `.unsupported` is honest truth (downgrade allowed).
            let capability = await source.createRoomCapability()
            switch capability {
            case .supported: canCreateRoomsByGateway[gateway.id] = true
            case .unsupported: canCreateRoomsByGateway[gateway.id] = false
            case .unknown: break
            }
        }
    }

    /// Rooms for one gateway (empty when unknown — honest absence).
    public func rooms(for gatewayID: GatewayID) -> [FleetRoom] {
        roomsByGateway[gatewayID] ?? []
    }

    // MARK: Slice 4 — room chat (D15/D16)

    /// The lazily-built room-command seam for a gateway (nil = fail-closed:
    /// controls hidden/disabled-with-explanation).
    public func roomCommandSeam(for gatewayID: GatewayID) -> (any RoomChatCommanding)? {
        if let existing = roomCommands[gatewayID] { return existing }
        guard let factory = roomCommandFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }),
              let seam = factory(gateway) else { return nil }
        roomCommands[gatewayID] = seam
        return seam
    }

    /// The lazily-built driver-status seam for a gateway.
    public func roomDriverStatusSeam(for gatewayID: GatewayID) -> (any RoomDriverStatusProviding)? {
        if let existing = roomDriverStatuses[gatewayID] { return existing }
        guard let factory = roomDriverStatusFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }),
              let seam = factory(gateway) else { return nil }
        roomDriverStatuses[gatewayID] = seam
        return seam
    }

    /// Builds a room-chat view model for one room (seams from this gateway).
    public func makeRoomChatViewModel(room: FleetRoom) -> RoomChatViewModel {
        RoomChatViewModel(
            room: room,
            commands: roomCommandSeam(for: room.id.gatewayID),
            driverStatus: roomDriverStatusSeam(for: room.id.gatewayID))
    }

    // MARK: Slice 5 — RoomLink (D19)

    /// The lazily-built RoomLink command seam for a gateway (nil = the
    /// RoomLink panel renders its honest no-connection state).
    public func roomLinkSeam(for gatewayID: GatewayID) -> (any RoomLinkCommanding)? {
        if let existing = roomLinks[gatewayID] { return existing }
        guard let factory = roomLinkFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }),
              let seam = factory(gateway) else { return nil }
        roomLinks[gatewayID] = seam
        return seam
    }

    /// Builds a RoomLink view model for one room.
    public func makeRoomLinkViewModel(room: FleetRoom) -> RoomLinkViewModel {
        RoomLinkViewModel(
            room: room,
            commands: roomLinkSeam(for: room.id.gatewayID))
    }

    /// Mention candidates from the LIVE fleet roster (D20): every gateway,
    /// hidden bots included (they stay mentionable by design §3.4).
    public func mentionCandidates() -> [MentionCandidate] {
        var botsByGateway: [GatewayID: [FleetBot]] = [:]
        for gateway in gateways {
            botsByGateway[gateway.id] = bots(on: gateway.id)
        }
        return FleetMentionCandidates.from(
            botsByGateway: botsByGateway,
            gatewayLabel: { [self] id in
                gateway(for: id)?.displayName ?? id.rawValue
            })
    }

    /// True when the gateway supports creating hosted rooms (F1: derived
    /// from the gateway-level `groups.capabilities` probe — a capable
    /// gateway with ZERO hosted rooms still offers Create Room, so the
    /// first room on a fresh gateway is creatable). Falls back to the
    /// legacy room-row check only when no probe answer has been recorded;
    /// never true on legacy-only evidence. Gates the Create Room entry
    /// (unsupported gateway: honest update-required explanation, not a
    /// dead button).
    public func canCreateRooms(on gatewayID: GatewayID) -> Bool {
        if let probed = canCreateRoomsByGateway[gatewayID] {
            return probed
        }
        return rooms(for: gatewayID).contains { room in
            room.id.provenance == .hosted
                && room.hosted?.advertisedMethods?.contains("groups.create") == true
                && room.hosted?.driverAvailable == true
        }
    }

    /// Creates a hosted room via the gateway's command seam. Throws the
    /// typed failure (unsupported old gateway → update explanation).
    public func createRoom(
        gatewayID: GatewayID, name: String, members: [RoomMemberCandidate],
        setupID: String = UUID().uuidString
    ) async throws -> FleetRoom {
        if let home = roomLinkSeam(for: gatewayID) as? any CrossGatewayRoomCommanding {
            return try await createLinkedRoom(home: home, gatewayID: gatewayID, name: name, members: members, setupID: setupID)
        }
        guard members.allSatisfy({ $0.route.gatewayID == gatewayID }) else {
            throw RoomCommandFailure.unsupportedMethod("Scoped RoomLink setup")
        }
        guard let seam = roomCommandSeam(for: gatewayID) else {
            throw RoomCommandFailure.notConnected
        }
        let wireMembers = HostedRoomMemberCodec.wireMembers(members, gatewayID: gatewayID)
        let roomID = try await seam.createRoom(name: name, members: wireMembers)
        // F1: a successful create is definitive gateway-level truth — the
        // entry must not regress if a later probe fails (.unknown).
        canCreateRoomsByGateway[gatewayID] = true
        // Reveal the room immediately from the authoritative create result.
        let room = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: roomID),
            name: name,
            members: members.map {
                FleetRoomMember(name: $0.displayName, handle: $0.route.profileSlug.rawValue)
            },
            hosted: HostedRoomState(
                authorityGatewayID: gatewayID.rawValue,
                authorityEpoch: 1,
                advertisedMethods: nil,
                driverAvailable: false))
        Task { await loadRooms() }
        return room
    }

    public func compatibleRoomGateways(homeID: GatewayID) async -> Set<GatewayID> {
        guard let home = roomLinkSeam(for: homeID) as? any CrossGatewayRoomCommanding,
              let snapshot = try? await home.roomLinkTarget(profile: "default"), snapshot.supportsHome else { return [] }
        var compatible = Set<GatewayID>()
        for gateway in gateways where gateway.id != homeID {
            guard let target = roomLinkSeam(for: gateway.id) as? any CrossGatewayRoomCommanding,
                  let targetSnapshot = try? await target.roomLinkTarget(profile: "default"),
                  targetSnapshot.supportsTarget,
                  targetSnapshot.negotiation.installationID != snapshot.negotiation.installationID else { continue }
            compatible.insert(gateway.id)
        }
        return compatible
    }

    private func createLinkedRoom(home: any CrossGatewayRoomCommanding, gatewayID: GatewayID,
                                  name: String, members: [RoomMemberCandidate], setupID: String) async throws -> FleetRoom {
        let remote = members.filter { $0.route.gatewayID != gatewayID }
        var targets: [Route: RoomLinkTargetSnapshot] = [:]
        if !remote.isEmpty {
            let homeSnapshot = try await home.roomLinkTarget(profile: "default")
            guard homeSnapshot.supportsHome else { throw RoomCommandFailure.unsupportedMethod("Direct RoomLink") }
            for member in remote {
                guard let target = roomLinkSeam(for: member.route.gatewayID) as? any CrossGatewayRoomCommanding else {
                    throw RoomCommandFailure.unsupportedMethod("Scoped RoomLink")
                }
                let snapshot = try await target.roomLinkTarget(profile: member.route.profileSlug.rawValue)
                guard snapshot.supportsTarget,
                      snapshot.negotiation.profile == member.route.profileSlug.rawValue,
                      snapshot.negotiation.installationID != homeSnapshot.negotiation.installationID else {
                    throw RoomCommandFailure.unsupportedMethod("Compatible profile-scoped RoomLink")
                }
                targets[member.route] = snapshot
            }
        }
        let room = try await home.createScopedRoom(roomID: setupID, name: name,
            members: members.map { CrossGatewayRoomSetup.member($0, target: targets[$0.route]) })
        for member in remote {
            guard let target = roomLinkSeam(for: member.route.gatewayID) as? any CrossGatewayRoomCommanding,
                  let snapshot = targets[member.route] else { throw RoomCommandFailure.notConnected }
            var grant: ScopedRoomGrant?
            do {
                let issued = try await target.inviteScopedRoom(room: room, profile: member.route.profileSlug.rawValue,
                    memberID: CrossGatewayRoomSetup.memberID(member.route))
                grant = issued
                try await home.registerScopedPeer(roomID: room.id.key,
                    memberID: CrossGatewayRoomSetup.memberID(member.route), target: snapshot, grant: issued)
            } catch {
                if let grant { try? await target.revokeScopedPeer(grant) }
                await loadRooms()
                throw RoomCommandFailure.rpcFailed("Room \(room.id.key) exists, but a remote link was not confirmed. The gateways must reach each other directly with matching execution policies. Retry this unchanged form to resume setup; no message was sent.", 0)
            }
        }
        await loadRooms()
        return room
    }

    /// Section registries for every gateway (best-effort).
    public func loadAllSections() async {
        for gateway in gateways {
            await botManagement.loadSections(from: gateway.id)
        }
    }

    /// H2: copy the latest connection-health snapshots into the observable
    /// state (the accumulator is fed continuously by the composition root).
    public func refreshHealthStats() async {
        healthStats = await health.snapshot()
    }

    /// Delete device-local cached fleet/session data without removing saved
    /// gateways or their Keychain credentials. This is the user-controlled
    /// privacy escape hatch exposed by Settings.
    public func clearLocalCache() async throws {
        // Stop any live session before deleting its persisted history. The
        // in-memory session objects are then discarded so stale transcript
        // rows cannot reappear in the UI after the user confirms deletion.
        connectionIntent.removeAll()
        await gatewaySessionInvalidatorAll?()
        await disconnectAll()
        try await cache.clearCachedData()
        activeConnections.removeAll()
        conversationSessions.removeAll()
        kanbanWatchers.removeAll()
        managementSeams.removeAll()
        learningSeams.removeAll()
        projectsSeams.removeAll()
        botModeChatSeams.removeAll()
        roomSources.removeAll()
        roomCommands.removeAll()
        roomDriverStatuses.removeAll()
        roomLinks.removeAll()
        connectionStates.removeAll()
        continueIndex.removeAll()
        gatewayFormDraft.clear()
        rosterSnapshot = nil
        cachedWatermarkCount = 0
        healthStats = [:]
        cachedBotsByGateway = [:]
        sessionsObservedAt = [:]
        sessionReadGenerations = [:]
        roomsByGateway = [:]
        canCreateRoomsByGateway = [:]
        observedRoomAttention = [:]
        rosterObservedAt = nil
        sessionsByRoute = [:]
        sessionReadErrors = [:]
    }

    // MARK: Connection lifecycle (runtime-owned, observable)

    /// Connect to a gateway: `connecting` → `connected`, or `failed(status)`.
    /// Idempotent-safe: a connect on an already-connecting OR already-connected
    /// gateway is ignored. (P0-7: the transport's `connect()` is itself now
    /// idempotent from `.open`, but the guard also prevents redundant work and
    /// keeps the observable lifecycle from flapping.)
    public func connect(to id: GatewayID) async {
        guard connectionStates[id] != .connecting,
              connectionStates[id] != .connected else { return }
        guard let gateway = gateways.first(where: { $0.id == id }) else { return }
        connectionIntent.record(id)
        connectionStates[id] = .connecting
        let connection = activeConnections[id] ?? connectionFactory(gateway, nil)
        activeConnections[id] = connection
        do {
            try await connection.connect()
            connectionStates[id] = GatewayConnectionState(status: connection.status)
            if connectionStates[id] == .connected {
                scheduleRosterSyncAfterConnectionRepair(for: id)
            }
        } catch let error as GatewayConnectivityError {
            let status = GatewayStatus(connectivityError: error)
            connectionStates[id] = .failed(status)
            switch status {
            case .authenticationRequired, .unsupported:
                connectionIntent.clear(id)
            default:
                break
            }
        } catch {
            connectionStates[id] = .failed(.offline)
        }
    }

    /// Disconnect cleanly and safely from every state (spec §31).
    public func disconnect(from id: GatewayID) async {
        connectionIntent.clear(id)
        // Manual Disconnect is transport control, not sign-out. Keep the
        // in-memory authenticated lease so an explicit later Connect mints a
        // fresh single-use ticket without another password-login burst.
        guard let connection = activeConnections[id] else {
            connectionStates[id] = .disconnected
            return
        }
        await connection.disconnect()
        connectionStates[id] = .disconnected
    }

    /// Tear down all live gateway sessions at a lifecycle boundary.
    ///
    /// The app lock protects presentation, not already-open sockets. This
    /// method is therefore called when the app backgrounds and before a lock
    /// screen is shown. Conversation sessions own their own connectivity
    /// seam, so they are explicitly disconnected in addition to the base
    /// gateway connections.
    public func disconnectAll() async {
        let connections = Array(activeConnections.values)
        let conversations = Array(conversationSessions.values)
        let kanban = Array(kanbanWatchers.values)
        let management = Array(managementSeams.values)
        let learning = Array(learningSeams.values)
        let projects = Array(projectsSeams.values)
        let botMode = Array(botModeChatSeams.values)
        let rooms = Array(roomSources.values)
        let roomCommandSeams = Array(self.roomCommands.values)
        let roomStatusSeams = Array(roomDriverStatuses.values)
        let roomLinkSeams = Array(self.roomLinks.values)

        for connection in connections {
            await connection.disconnect()
        }
        for conversation in conversations {
            await conversation.disconnect()
        }
        for watcher in kanban {
            await watcher.stop()
        }
        for seam in management {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        for seam in learning {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        for seam in projects {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        for seam in botMode {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        for seam in rooms {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        for seam in roomCommandSeams {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        for seam in roomStatusSeams {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        for seam in roomLinkSeams {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }

        for id in Set(activeConnections.keys)
            .union(conversationSessions.keys)
            .union(kanbanWatchers.keys)
            .union(managementSeams.keys)
            .union(learningSeams.keys)
            .union(projectsSeams.keys)
            .union(botModeChatSeams.keys)
            .union(roomSources.keys)
            .union(self.roomCommands.keys)
            .union(roomDriverStatuses.keys)
            .union(self.roomLinks.keys) {
            connectionStates[id] = .disconnected
        }
    }

    /// Reconnect: tear down cleanly, then reconnect. Observable as
    /// `disconnected` → `connecting` → `connected`/`failed`.
    public func reconnect(to id: GatewayID) async {
        await disconnect(from: id)
        await connect(to: id)
    }

    /// Reconnect only gateways the user explicitly chose to keep connected.
    /// Transport teardown caused by suspension, backgrounding, or app lock
    /// never clears this intent. Each gateway is restored independently;
    /// auth/unsupported failures clear only that gateway's intent, while
    /// transient failures remain retryable.
    public func restoreIntendedConnections() async {
        guard !gateways.isEmpty else {
            connectionIntent.prune(to: [])
            return
        }
        for gateway in gateways where connectionIntent.isIntended(gateway.id) {
            if connectionStates[gateway.id] == .connected || connectionStates[gateway.id] == .connecting {
                continue
            }
            if let connection = activeConnections[gateway.id], !connection.status.isReachable {
                await connection.disconnect()
                activeConnections[gateway.id] = nil
            }
            await connect(to: gateway.id)
        }
    }

    public func isConnectionIntended(_ id: GatewayID) -> Bool {
        connectionIntent.isIntended(id)
    }

    // MARK: Roster accessors (for the Bots / Sessions screens)

    /// Bots owned by a gateway from the latest roster snapshot (fail closed:
    /// empty while the gateway is unreachable or the snapshot is stale).
    public func bots(on id: GatewayID) -> [FleetBot] {
        rosterSnapshot?.bots(on: id) ?? []
    }

    /// The single bot for an exact route, or nil (fail closed).
    public func bot(for route: Route) -> FleetBot? {
        rosterSnapshot?.bot(for: route)
    }

    /// FOS-5 (SPEC §9 ghosts): the bot for an exact route from EITHER the
    /// live roster or the offline-ghost cache. A ghost (owning gateway
    /// failed its refresh) retains identity and opens the snapshot inspector
    /// + cached sessions — `nil` here is what made a ghost row dead-end at
    /// "Bot Unavailable". Never a name fallback: the exact Route is required.
    public func botIncludingGhost(for route: Route) -> FleetBot? {
        if let live = rosterSnapshot?.bot(for: route) { return live }
        return cachedBotsByGateway[route.gatewayID]?.first { $0.route == route }
    }

    /// Whether `route` currently resolves ONLY through the ghost cache (the
    /// owning gateway failed its latest refresh) — drives the snapshot
    /// inspector presentation in Bot Detail.
    public func isGhostRoute(_ route: Route) -> Bool {
        guard rosterSnapshot?.bot(for: route) == nil else { return false }
        return cachedBotsByGateway[route.gatewayID]?.contains { $0.route == route } == true
    }

    /// P0-7 multiplexer presence for one bot route, from the latest roster
    /// snapshot (fail closed: no snapshot yet → `.unknown`, which renders
    /// offline-gray — never a fabricated online).
    public func botPresence(for route: Route) -> BotPresence {
        rosterSnapshot?.botPresence(for: route) ?? .unknown
    }

    /// The registered gateway for an ID, or nil.
    public func gateway(for id: GatewayID) -> FleetGateway? {
        gateways.first { $0.id == id }
    }

    // MARK: Registry passthroughs (U2 Gateway management reuses these)

    public func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
        let gateway = try await registry.addGateway(registration)
        await reloadGateways()
        return gateway
    }

    /// Register a gateway and optionally store its credential in one seam
    /// call (U2 add-gateway form). The credential is passed straight to the
    /// registry's Keychain-safe store — it is never held by the view layer
    /// or logged. `nil` credential → registration only.
    public func addGateway(
        _ registration: GatewayRegistration,
        credential: GatewayCredential?,
        confirmsTLSFirstUse: Bool = false
    ) async throws -> FleetGateway {
        let gateway = try await registry.addGateway(registration)
        if confirmsTLSFirstUse {
            try await tlsApprovalStore?.approveFirstUse(for: gateway.id)
        }
        if let credential {
            try await registry.saveCredential(credential, for: gateway.id)
        }
        await reloadGateways()
        return gateway
    }

    /// Apply a partial edit to a gateway's display name / endpoint / auth
    /// config. Throws `.notFound` / `.invalidEndpoint` from the registry seam.
    public func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        let previous = gateways.first(where: { $0.id == id })
        let gateway = try await registry.updateGateway(id, edits: edits)
        if previous?.endpoint != gateway.endpoint
            || previous?.authConfiguration != gateway.authConfiguration
            || previous?.transport != gateway.transport {
            await gatewaySessionInvalidator?(id)
            await retireGatewaySessions(id)
        }
        await reloadGateways()
        return gateway
    }

    private func retireGatewaySessions(_ id: GatewayID) async {
        // P1-8: retire session resources with the gateway — tear down the
        // live connection (not just drop the reference), release the
        // conversation session, and clear observable lifecycle state.
        if let connection = activeConnections[id] { await connection.disconnect() }
        if let conversation = conversationSessions[id] { await conversation.disconnect() }
        if let watcher = kanbanWatchers.removeValue(forKey: id) { await watcher.stop() }
        if let seam = managementSeams[id] {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        if let seam = learningSeams[id] {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        if let seam = projectsSeams[id] {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        if let seam = botModeChatSeams[id] {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        if let seam = roomSources[id] {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        if let seam = roomCommands[id] {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        if let seam = roomDriverStatuses[id] {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        if let seam = roomLinks[id] {
            await (seam as? any GatewaySessionDisconnecting)?.disconnect()
        }
        activeConnections[id] = nil
        conversationSessions[id] = nil
        managementSeams[id] = nil
        learningSeams[id] = nil
        projectsSeams[id] = nil
        botModeChatSeams[id] = nil
        roomSources[id] = nil
        roomCommands[id] = nil
        roomDriverStatuses[id] = nil
        roomLinks[id] = nil
        roomsByGateway[id] = nil
        canCreateRoomsByGateway[id] = nil
        connectionStates[id] = nil
        await botManagement.retireGateway(id)
    }

    public func removeGateway(_ id: GatewayID) async throws {
        try await registry.removeGateway(id)
        connectionIntent.clear(id)
        await gatewaySessionInvalidator?(id)
        await retireGatewaySessions(id)
        testResults[id] = nil
        testResultObservedAt[id] = nil
        // FOS-4 (SPEC §8 removal): a removed source's saved recent-open
        // entries must not resolve to another gateway — prune the Continue
        // index and the observed room attention for this gateway.
        continueIndex.prune(gatewayID: id)
        observedRoomAttention[id] = nil
        summarySourceStates[id] = nil
        let removedRoutes = sessionRoutes(on: id)
        for route in removedRoutes {
            invalidateSessions(for: route)
        }
        // H2: drop the gateway's accumulated + persisted health stats.
        await health.forget(gatewayID: id)
        healthStats = await health.snapshot()
        await reloadGateways()
    }

    // MARK: FOS-4 — Continue open recording (SPEC §7/§17)

    /// Record an open of a conversation whose destination actually resolved
    /// (called by ConversationView once the session is live). Never records
    /// a failed link; identity is source-qualified (Route + sessionID).
    public func recordConversationOpen(route: Route, sessionID: String?, canonical: Bool, title: String, subtitle: String) {
        guard let sessionID, !sessionID.isEmpty else { return }
        continueIndex.recordConversationOpen(
            route: route, sessionID: sessionID, canonical: canonical,
            title: title, subtitle: subtitle)
        // Opening can mint a new session; stale only the owning route.
        sessionsObservedAt[route] = nil
    }

    /// Record an open of an exact room (called by RoomChatView).
    public func recordRoomOpen(room: FleetRoom, title: String, subtitle: String) {
        continueIndex.recordRoomOpen(room: room.id, title: title, subtitle: subtitle)
    }

    // MARK: Auth config entry (M7 credential flow — Keychain-safe)

    /// Store a credential for a gateway (Keychain via the registry seam; the
    /// secret never transits the UI model or logs). Marks auth configured.
    public func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {
        try await registry.saveCredential(credential, for: id)
        await gatewaySessionInvalidator?(id)
        await reloadGateways()
    }

    /// Clear the stored credential for a gateway (no-op when absent).
    public func clearCredential(for id: GatewayID) async throws {
        try await registry.clearCredential(for: id)
        await gatewaySessionInvalidator?(id)
        await reloadGateways()
    }

    /// Whether a credential is currently stored for a gateway (Keychain).
    public func hasCredential(for id: GatewayID) async -> Bool {
        await registry.hasCredential(for: id)
    }

    // MARK: TLS trust lifecycle (T3)

    /// Record the user's explicit decision to trust the first secure
    /// certificate presented by a gateway. The transport will still pin the
    /// presented SPKI only after this decision is present.
    public func approveTLSFirstUse(for id: GatewayID) async throws {
        guard gateways.contains(where: { $0.id == id }) else {
            throw GatewayRegistryError.notFound(id)
        }
        try await tlsApprovalStore?.approveFirstUse(for: id)
    }

    /// Clear both the stored SPKI and the first-use decision. The next secure
    /// connection is blocked until the user reviews the gateway again and
    /// explicitly confirms the new certificate (re-pair/rotation flow).
    public func resetTLSTrust(for id: GatewayID) async throws {
        guard gateways.contains(where: { $0.id == id }) else {
            throw GatewayRegistryError.notFound(id)
        }
        try await tlsPinStore?.deletePin(for: id)
        try await tlsApprovalStore?.resetFirstUseApproval(for: id)
    }

    /// Public-key fingerprint currently pinned for a gateway, for the
    /// non-secret trust-status display. The full value is intentionally not
    /// logged; the UI may show the stable abbreviated description.
    public func tlsPin(for id: GatewayID) async -> SPKIFingerprint? {
        try? await tlsPinStore?.loadPin(for: id)
    }

    // MARK: Test connection (§13 reachable/unreachable probe, observable)

    /// Probe a gateway's reachability and capability surface. Observable:
    /// `testingGatewayIDs` while in flight, then `testResults[id]` set to the
    /// classified §13 result. A classified failure (offline / authRequired /
    /// unsupported / degraded) is stored, never thrown to the UI — only an
    /// absent gateway throws (from the registry seam).
    public func testConnection(to id: GatewayID) async throws {
        guard gateways.contains(where: { $0.id == id }) else {
            throw GatewayRegistryError.notFound(id)
        }
        testingGatewayIDs.insert(id)
        defer { testingGatewayIDs.remove(id) }
        let result = try await registry.testConnection(to: id)
        testResults[id] = result
        testResultObservedAt[id] = Date()
        // Reflect the probe into the observable connection lifecycle so the
        // row shows the §13 state without a separate connect attempt.
        connectionStates[id] = GatewayConnectionState(status: result.status)
    }

    // MARK: Session list (Bot detail — read-only `session.list` seam)

    /// Load a bot's sessions via the read-only `session.list` seam, cached in
    /// the observable `sessionsByRoute`. Fail-closed: a classified read error
    /// is recorded (non-secret) so the UI renders an error state, never a
    /// crash.
    public func loadSessions(for route: Route) async {
        guard !loadingRoutes.contains(route) else { return }
        let generation = sessionReadGenerations[route, default: 0]
        loadingRoutes.insert(route)
        defer { loadingRoutes.remove(route) }
        do {
            let sessions = try await sessionList.fetchSessions(for: route, limit: 200)
            guard sessionReadGenerations[route, default: 0] == generation else { return }
            sessionsByRoute[route] = sessions
            sessionReadErrors[route] = nil
            sessionsObservedAt[route] = Date()
        } catch let error as RosterError {
            guard sessionReadGenerations[route, default: 0] == generation else { return }
            sessionReadErrors[route] = Redaction.safeErrorDescription(error)
        } catch {
            guard sessionReadGenerations[route, default: 0] == generation else { return }
            sessionReadErrors[route] = Redaction.safeErrorDescription(error)
        }
    }

    // MARK: Chats session freshness

    /// When this route's sessions were last successfully observed.
    public func sessionsLastObserved(_ route: Route) -> Date? {
        sessionsObservedAt[route]
    }

    /// Missing or never-successfully-read routes are stale. A failed read
    /// retains the old timestamp (or nil), so stale data cannot be laundered
    /// as fresh.
    public func needsSessionRefresh(_ route: Route, now: Date = Date()) -> Bool {
        guard sessionsByRoute[route] != nil else { return true }
        guard let observed = sessionsObservedAt[route] else { return true }
        return now.timeIntervalSince(observed) >= Self.sessionFreshnessTTL
    }

    /// Narrowly invalidate one route's cached observation.
    public func invalidateSessions(for route: Route) {
        sessionReadGenerations[route, default: 0] += 1
        sessionsObservedAt[route] = nil
    }

    /// Narrowly invalidate observations owned by one gateway.
    public func invalidateSessions(on gatewayID: GatewayID) {
        let routes = sessionRoutes(on: gatewayID)
        for route in routes {
            invalidateSessions(for: route)
        }
    }

    /// All session routes with any retained cache, freshness, or generation
    /// state. A successful first read may have freshness state without a
    /// generation entry, so gateway-scoped invalidation must include all
    /// three stores.
    private func sessionRoutes(on gatewayID: GatewayID) -> Set<Route> {
        Set(sessionReadGenerations.keys)
            .union(sessionsObservedAt.keys)
            .union(sessionsByRoute.keys)
            .filter { $0.gatewayID == gatewayID }
    }

    /// Refresh missing/stale routes with an explicit bounded concurrency
    /// window. `force` is reserved for explicit pull-to-refresh behavior.
    public func refreshSessions(
        routes: [Route],
        force: Bool = false,
        concurrencyLimit: Int = 4,
        now: Date = Date()
    ) async {
        var byGateway: [GatewayID: [Route]] = [:]
        var gatewayOrder: [GatewayID] = []
        for route in routes where force || needsSessionRefresh(route, now: now) {
            if byGateway[route.gatewayID] == nil { gatewayOrder.append(route.gatewayID) }
            byGateway[route.gatewayID, default: []].append(route)
        }

        var ordered: [Route] = []
        var remaining = !gatewayOrder.isEmpty
        while remaining {
            remaining = false
            for gateway in gatewayOrder {
                guard var list = byGateway[gateway], !list.isEmpty else { continue }
                ordered.append(list.removeFirst())
                byGateway[gateway] = list
                remaining = true
            }
        }
        guard !ordered.isEmpty else { return }

        let bound = max(1, concurrencyLimit)
        await withTaskGroup(of: Void.self) { group in
            var iterator = ordered.makeIterator()
            var inFlight = 0
            func addNext() {
                while inFlight < bound, let route = iterator.next() {
                    inFlight += 1
                    group.addTask { await self.loadSessions(for: route) }
                }
            }
            addNext()
            for await _ in group {
                inFlight -= 1
                addNext()
            }
        }
    }

    /// Sessions for a route, or `nil` when never fetched.
    public func sessions(for route: Route) -> [SessionSummary]? {
        sessionsByRoute[route]
    }

    // MARK: U3 — conversation sessions (per-gateway, lazily built)

    /// The conversation session for a gateway, building it on first use via
    /// the injected `FleetConversationFactory` (one per gateway; survives view
    /// teardowns so a reconnect mid-conversation stays on the same transport).
    /// Returns `nil` when the factory is not wired or the gateway is absent
    /// (fail closed).
    public func conversationSession(for gatewayID: GatewayID) -> (any ConversationSessionProviding)? {
        if let existing = conversationSessions[gatewayID] { return existing }
        guard let factory = conversationFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let session = factory(gateway, nil)
        conversationSessions[gatewayID] = session
        return session
    }

    /// Build the U3 Conversation view model for a route (nil when the gateway
    /// has no conversation session wired — the screen renders an unavailable
    /// state, fail closed). R10-T4: the shared voice engine rides along
    /// (fail-closed default inside the VM when nil).
    public func makeConversationViewModel(route: Route, sessionID: String?) -> ConversationViewModel? {
        guard let session = conversationSession(for: route.gatewayID) else { return nil }
        let model = ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: sessionID,
            biometrics: biometrics,
            voice: voiceEngineFactory?()
        )
        model.prepareBotDraft = { [weak self] text, openedID in
            guard let self else { return BotConversationDraft(text: text) }
            let canonical = self.isCanonicalBotChat(route: route, sessionID: openedID)
                || sessionID.map { self.isCanonicalBotChat(route: route, sessionID: $0) } == true
            let protected = BotConversationDraft.protectingCanonical(text, isCanonical: canonical)
            if protected.notice != nil { return protected }
            return BotConversationMentions.prepare(text: text, roster: self.mentionCandidates(), current: route,
                gatewayLabel: { self.gateway(for: $0)?.displayName ?? $0.rawValue })
        }
        return model
    }

    // MARK: Kanban board (t_3b321b7b)

    /// Build the read-only kanban board watcher for a gateway. Nil when no
    /// factory is wired (the screen renders its unavailable state, fail
    /// closed).
    public func makeKanbanWatcher(for gateway: FleetGateway) -> (any KanbanBoardWatching)? {
        if let existing = kanbanWatchers[gateway.id] { return existing }
        guard let watcher = kanbanWatcherFactory?(gateway) else { return nil }
        kanbanWatchers[gateway.id] = watcher
        return watcher
    }

    // MARK: Management panes (R9-T5/T6 — cron + skills)

    /// Build the management seam for a gateway. Nil when no factory is
    /// wired (the panes render their unavailable state, fail closed).
    public func makeManagementSeam(for gatewayID: GatewayID) -> (any GatewayManagementProviding)? {
        if let existing = managementSeams[gatewayID] { return existing }
        guard let factory = managementSeamFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        managementSeams[gatewayID] = seam
        return seam
    }

    // MARK: True Bots Mode — canonical Bot Chat

    /// Build the Bot Mode chat seam for a gateway. Nil when no factory is
    /// wired (the tap falls back to the sessions list, fail closed).
    public func makeBotModeChat(for gatewayID: GatewayID) -> (any BotModeChatProviding)? {
        if let existing = botModeChatSeams[gatewayID] { return existing }
        guard let factory = botModeChatFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        botModeChatSeams[gatewayID] = seam
        return seam
    }

    /// Resolve the canonical Bot Chat open target for a bot tap, applying
    /// the fail-closed contract (see `CanonicalChatResolver`). Recency never
    /// selects the target — `latestSession` is never substituted.
    ///
    /// Returns the session id to open, or a retryable error message. NEVER
    /// creates a chat on an unconfirmed lookup (no transient fork).
    public func resolveCanonicalChatTarget(for bot: FleetBot) async -> Result<String, BotChatUnavailable> {
        // The roster-reported canonical_session is authoritative identity
        // info; the tap still verifies against a live title-exact lookup so
        // a stale roster can't open a dead id blindly.
        guard let seam = makeBotModeChat(for: bot.route.gatewayID) else {
            return .failure(BotChatUnavailable(message: "Bot Chat is unavailable on this gateway"))
        }
        let rosterID = bot.canonicalSession?.id
        do {
            let lookup = try await seam.lookupCanonicalChat(profile: bot.route.profileSlug.rawValue)
            let rows = lookup.rows.map {
                SessionSummary(id: $0.id, title: $0.title, preview: $0.preview, messageCount: $0.messageCount)
            }
            // resolved_id (compression tip) travels as the row id on the
            // exact-title wire; attach it so the resolver prefers the tip.
            let resolution: CanonicalChatResolution
            if let first = lookup.rows.first, let tip = first.openID, tip != first.id {
                resolution = CanonicalChatResolver.resolve(
                    lookupRows: [SessionSummary(id: first.id, title: first.title,
                                                preview: first.preview, messageCount: first.messageCount)],
                    rosterCanonicalID: rosterID,
                    lookupError: nil)
                // The resolver's existing-ref openID falls back to row id;
                // the tip (already validated non-empty by openID) wins.
                if case .existing = resolution {
                    return .success(tip)
                }
            } else {
                resolution = CanonicalChatResolver.resolve(
                    lookupRows: rows, rosterCanonicalID: rosterID, lookupError: nil)
            }
            switch BotChatPlanner.plan(from: resolution) {
            case .openCanonical(let ref):
                if let id = ref.openID { return .success(id) }
                return .failure(BotChatUnavailable(message: "Bot Chat registry returned a malformed id — not starting a new chat"))
            case .createThenOpen:
                // Confirmed miss only: safe hidden creation with eager title.
                let created = try await seam.createCanonicalChat(profile: bot.route.profileSlug.rawValue)
                return .success(created)
            case .unavailable(let message):
                return .failure(BotChatUnavailable(message: message))
            }
        } catch {
            // RPC failure of EITHER lookup or creation is retryable — never
            // mint/fork from the catch path. User-facing copy stays clean:
            // the internal error chain is logged out-of-band, never shown.
            #if DEBUG
            print("canonical chat resolve failed for \(bot.route.id): \(error)")
            #endif
            return .failure(BotChatUnavailable(
                message: "Couldn't check the Bot Chat registry — not starting a new chat"))
        }
    }

    // MARK: Memory graph (R9-T7 — learning star map)

    /// Build the learning seam for a gateway. Nil when no factory is wired
    /// (the pane renders its unavailable state, fail closed).
    public func makeLearningSeam(for gatewayID: GatewayID) -> (any GatewayLearningProviding)? {
        if let existing = learningSeams[gatewayID] { return existing }
        guard let factory = learningSeamFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        learningSeams[gatewayID] = seam
        return seam
    }

    /// The learning-graph snapshot store (offline browse), when wired.
    public var learningSnapshotStore: (any LearningGraphSnapshotStoring)? {
        learningSnapshotStore_
    }

    // MARK: Projects browser (R10-T3 — remote file browser)

    /// Build the projects seam for a gateway. Nil when no factory is
    /// wired (the browser renders its unavailable state, fail closed).
    public func makeProjectsSeam(for gatewayID: GatewayID) -> (any GatewayProjectsProviding)? {
        if let existing = projectsSeams[gatewayID] { return existing }
        guard let factory = projectsSeamFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        projectsSeams[gatewayID] = seam
        return seam
    }

    /// The projects-tree snapshot store (offline browse), when wired.
    public var projectsSnapshotStore: (any ProjectsSnapshotStoring)? {
        projectsSnapshotStore_
    }
}
