import Foundation
import Observation
import FleetCore

/// R9-T2/T3/T4 — conversation tooling view model: sticky per-device model
/// pick, live context meter state, steer/rename/fork actions.
///
/// STICKY-LOCAL MODEL RULE (the desktop parity contract): the selected
/// model+provider is held HERE (per-device, `UserDefaults`-backed) and rides
/// `session.create {model, provider}` — the per-session override the gateway
/// builds into the agent (methods_session.py:50-53: "never a global config
/// write"). There is NO code path from this VM to `config.set` for models:
/// the picker cannot mutate the profile default even by accident. A resumed
/// session keeps whatever model it was created with (its session.info
/// readback updates the display only).
@MainActor
@Observable
public final class ConversationToolingViewModel {

    // MARK: Observable state

    /// The gateway's available models (nil until model.options resolves).
    public private(set) var modelChoices: [ModelChoice]?
    /// The sticky per-device selection (model id + provider slug). Persists
    /// across launches; nil = "follow the profile default" (session.create
    /// with no model param — the gateway inherits).
    public private(set) var selectedModel: ModelChoice?
    /// Sticky per-device thinking effort (nil = inherit the profile).
    /// Rides `session.create {reasoning_effort}` only — never a config write.
    public private(set) var selectedEffort: ReasoningEffort?
    /// True while model.options is in flight (picker loading state).
    public private(set) var isLoadingModels = false
    /// Fail-soft model list error (non-secret).
    public private(set) var modelLoadError: String?

    /// Latest context meter snapshot — fed by the streamed `session.usage`
    /// event (mid-turn) and refreshed by the `session.usage` RPC on turn
    /// completion. Nil = no data yet; `hasContextGauge == false` = the
    /// gateway honestly reports no gauge.
    public private(set) var usage: SessionUsageSnapshot?
    /// The fetched context breakdown for the detail sheet (nil until
    /// fetched; a fetch failure sets contextError).
    public private(set) var breakdown: ContextBreakdown?
    public private(set) var isLoadingBreakdown = false
    public private(set) var contextError: String?

    /// Steer/rename/fork result surfaces (transient, non-secret).
    public private(set) var steerNotice: String?
    public private(set) var renameNotice: String?
    public private(set) var forkError: String?

    // MARK: Injected seams

    private let tooling: any ConversationToolingProviding
    /// Per-device sticky store key (gateway-scoped so each gateway's pick
    /// is independent — different gateways serve different providers).
    private let persistenceKey: String
    private let effortKey: String
    private var boundSessionID: String?

    public init(
        tooling: any ConversationToolingProviding,
        gatewayID: GatewayID
    ) {
        self.tooling = tooling
        self.persistenceKey = "fleet.modelpick.\(gatewayID.rawValue)"
        self.effortKey = "fleet.effortpick.\(gatewayID.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: effortKey) {
            self.selectedEffort = ReasoningEffort(rawValue: raw)
        }
        // Restore the sticky pick (fail-soft: corrupt store → follow default).
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let choice = try? JSONDecoder().decode(ModelChoice.self, from: data) {
            self.selectedModel = choice
        }
    }

    // MARK: Binding

    /// Bind to the open runtime session (usage/context/steer calls ride it).
    public func bind(sessionID: String?) {
        boundSessionID = sessionID
    }

    // MARK: Model picker (sticky, per-device, never a config write)

    /// Load `model.options`. Fail-soft: an error surfaces on the picker, the
    /// previous list (if any) stays.
    public func loadModelChoices() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let choices = try await tooling.modelChoices(sessionID: boundSessionID)
            modelLoadError = nil
            modelChoices = choices
        } catch {
            modelLoadError = ConversationViewModel.nonSecret(error)
        }
    }

    /// Select a model (sticky per-device). Persists immediately; NO wire
    /// call — the selection rides the NEXT `session.create`. Deselect
    /// (nil) returns to "follow the profile default".
    public func select(_ choice: ModelChoice?) {
        selectedModel = choice
        if let choice,
           let data = try? JSONEncoder().encode(choice) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
        }
    }

    /// Pick a thinking effort (sticky per-device; nil = profile default).
    /// No wire call — rides the NEXT `session.create`.
    public func selectEffort(_ effort: ReasoningEffort?) {
        selectedEffort = effort
        if let effort {
            UserDefaults.standard.set(effort.rawValue, forKey: effortKey)
        } else {
            UserDefaults.standard.removeObject(forKey: effortKey)
        }
    }

    /// Efforts offered for the current pick (capabilities of the selected,
    /// else the gateway-current model; unknown → every level).
    public var availableEfforts: [ReasoningEffort] {
        let model = selectedModel ?? modelChoices?.first(where: \.isCurrent)
        return model?.availableEfforts ?? ReasoningEffort.allCases
    }

    /// The params the conversation open should ride on `session.create`:
    /// the sticky pick when set, else nil/nil (inherit the profile).
    public var createModelParams: (model: String?, provider: String?) {
        (selectedModel?.model, selectedModel?.provider)
    }

    // MARK: Context meter

    /// Apply a streamed `session.usage` tick (mid-turn live meter feed).
    public func applyUsage(_ snapshot: SessionUsageSnapshot) {
        usage = snapshot
        // A tick with a real gauge clears a stale fetch error.
        if snapshot.hasContextGauge { contextError = nil }
    }

    /// Refresh via the `session.usage` RPC (turn completion / sheet open).
    public func refreshUsage() async {
        guard let sid = boundSessionID else { return }
        // Fail-soft: the streamed ticks keep the last snapshot.
        if let snapshot = try? await tooling.usage(sessionID: sid) {
            applyUsage(snapshot)
        }
    }

    /// Fetch `session.context_breakdown` for the detail sheet.
    public func loadBreakdown() async {
        guard let sid = boundSessionID else { return }
        isLoadingBreakdown = true
        defer { isLoadingBreakdown = false }
        do {
            breakdown = try await tooling.contextBreakdown(sessionID: sid)
            contextError = nil
        } catch {
            contextError = ConversationViewModel.nonSecret(error)
        }
    }

    /// Meter level for the current snapshot (normal/warn/alert thresholds:
    /// <70 / 70–90 / >90).
    public var meterLevel: ContextMeterLevel? {
        usage?.contextPercent.map(ContextMeterLevel.level(forPercent:))
    }

    // MARK: Steer / rename / fork

    /// Steer the running turn: injects guidance into the next tool result
    /// WITHOUT interrupting (no new user turn). Surfaces a notice either
    /// way — queued or rejected — never silent.
    public func steer(text: String) async {
        guard let sid = boundSessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let queued = try await tooling.steer(sessionID: sid, text: trimmed)
            steerNotice = queued
                ? "Steer queued — the model sees it on its next step."
                : "Steer rejected — no turn is running to steer."
        } catch {
            steerNotice = "Steer failed: \(ConversationViewModel.nonSecret(error))"
        }
    }

    /// Rename the session (`session.title`). Returns the resolved title so
    /// the caller can update its own header state; nil on failure (notice
    /// set).
    @discardableResult
    public func rename(title: String) async -> String? {
        guard let sid = boundSessionID else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let resolved = try await tooling.renameSession(sessionID: sid, title: trimmed)
            renameNotice = nil
            return resolved
        } catch {
            renameNotice = "Rename failed: \(ConversationViewModel.nonSecret(error))"
            return nil
        }
    }

    /// Fork the session (`session.branch`). Returns the NEW conversation
    /// session for the caller to navigate to; nil on failure (forkError set
    /// — e.g. 4008 "nothing to branch — send a message first").
    public func fork(name: String?) async -> ConversationSession? {
        guard let sid = boundSessionID else { return nil }
        do {
            let branch = try await tooling.branchSession(sessionID: sid, name: name)
            forkError = nil
            return branch
        } catch {
            forkError = ConversationViewModel.nonSecret(error)
            return nil
        }
    }
}

extension ModelChoice: Codable {
    enum CodingKeys: String, CodingKey {
        case model, provider, providerName, isCurrent, supportsReasoning, canDisableReasoning
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let model = try c.decode(String.self, forKey: .model)
        let provider = try c.decode(String.self, forKey: .provider)
        let providerName = try c.decode(String.self, forKey: .providerName)
        let isCurrent = try c.decode(Bool.self, forKey: .isCurrent)
        self.init(
            model: model, provider: provider, providerName: providerName, isCurrent: isCurrent,
            supportsReasoning: try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning),
            canDisableReasoning: try c.decodeIfPresent(Bool.self, forKey: .canDisableReasoning))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(provider, forKey: .provider)
        try c.encode(providerName, forKey: .providerName)
        try c.encode(isCurrent, forKey: .isCurrent)
        try c.encodeIfPresent(supportsReasoning, forKey: .supportsReasoning)
        try c.encodeIfPresent(canDisableReasoning, forKey: .canDisableReasoning)
    }
}
