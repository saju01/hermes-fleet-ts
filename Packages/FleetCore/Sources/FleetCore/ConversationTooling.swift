import Foundation

/// R9-T2/T3/T4 — conversation tooling domain: model picker, context meter,
/// session steering/rename/fork.
///
/// Wire shapes verified against hermes-agent 0.21.0:
/// - `model.options` (tui_gateway/methods_complete.py:469 →
///   hermes_cli/inventory.py:328 `build_models_payload`): result
///   `{providers: [{slug, name, is_current, authenticated, models: [...],
///   ...}], model, provider}`. PER-SESSION model selection rides
///   `session.create {model, provider}` ONLY (methods_session.py:50-53 —
///   "Honor each as a PER-SESSION override … never a global config write");
///   `prompt.submit` takes NO model param (methods_prompt.py:287+). The
///   sticky-local rule: picking a model never writes the profile default.
/// - `session.usage` (methods_session.py:1828 → server.py:7512 `_get_usage`):
///   `{model, input, output, reasoning, prompt, completion, total, calls,
///   context_used?, context_max?, context_percent?, ...}` — the context
///   fields are emitted ONLY when the compressor reports a real current-
///   window occupancy (server.py:7542-7550), so a missing gauge is honest
///   "unknown", never 0%.
/// - streamed `session.usage` event (server.py:13133): mid-turn ticks every
///   ~1s carrying `{"usage": _get_usage(agent)}` — the live context meter
///   feed while a turn runs.
/// - `session.context_breakdown` (methods_session.py:1852 →
///   agent/context_breakdown.py:163): `{categories: [{id, label, tokens,
///   color}], context_max, context_percent, context_used, estimated_total,
///   model}`.
/// - `session.steer` (methods_session.py:3750): params `{session_id, text}`
///   → `{status: "queued"|"rejected", text}` — injects guidance into the
///   NEXT tool result without interrupting (no new user turn).
/// - `session.title` (methods_session.py:1427): params
///   `{session_id, title}` → `{pending: Bool, title}` (pending=true only
///   when the DB row write was deferred).
/// - `session.branch` (methods_session.py:3282): params
///   `{session_id, count?, name?}` → the full new-session payload
///   `{session_id, stored_session_id, title, parent, message_count,
///   messages, info}` (same projection as session.create/resume).

/// One selectable model in the picker: a provider's model id, flattened
/// from the `model.options` provider rows for search/list rendering.
public struct ModelChoice: Identifiable, Hashable, Sendable {
    /// Stable identity: "provider/model" (unique even when two providers
    /// serve ids that collide).
    public let id: String
    /// The model id sent as `session.create {model}` (mono rendering).
    public let model: String
    /// The owning provider slug (`session.create {provider}`).
    public let provider: String
    /// Human provider name for section headers.
    public let providerName: String
    /// Whether this is the gateway's currently-active model+provider
    /// (`is_current` on the provider row + the payload's `model`).
    public let isCurrent: Bool
    /// `capabilities[model].reasoning` from `model.options` (nil = unknown).
    public let supportsReasoning: Bool?
    /// `capabilities[model].can_disable_reasoning` (nil = unknown).
    public let canDisableReasoning: Bool?

    public init(
        model: String, provider: String, providerName: String, isCurrent: Bool,
        supportsReasoning: Bool? = nil, canDisableReasoning: Bool? = nil
    ) {
        self.id = "\(provider)/\(model)"
        self.model = model
        self.provider = provider
        self.providerName = providerName
        self.isCurrent = isCurrent
        self.supportsReasoning = supportsReasoning
        self.canDisableReasoning = canDisableReasoning
    }

    /// Thinking levels this model can take (see `ReasoningEffort.available`).
    public var availableEfforts: [ReasoningEffort] {
        ReasoningEffort.available(reasoning: supportsReasoning, canDisableReasoning: canDisableReasoning)
    }

    /// Short display form for the composer chip (last path segment when the
    /// id is namespaced, else the id itself).
    public var shortName: String {
        if let slash = model.lastIndex(of: "/"), model.distance(from: model.startIndex, to: slash) < model.count - 1 {
            return String(model[model.index(after: slash)...])
        }
        return model
    }
}

/// `session.usage` snapshot (the `_get_usage` shape, context fields optional).
public struct SessionUsageSnapshot: Hashable, Sendable {
    public let model: String?
    public let input: Int
    public let output: Int
    public let total: Int
    public let calls: Int
    /// Current context-window occupancy — present ONLY when the compressor
    /// reports a real value (server.py:7542); nil means "unknown", never 0.
    public let contextUsed: Int?
    public let contextMax: Int?
    public let contextPercent: Int?

    public init(
        model: String? = nil,
        input: Int = 0,
        output: Int = 0,
        total: Int = 0,
        calls: Int = 0,
        contextUsed: Int? = nil,
        contextMax: Int? = nil,
        contextPercent: Int? = nil
    ) {
        self.model = model
        self.input = input
        self.output = output
        self.total = total
        self.calls = calls
        self.contextUsed = contextUsed
        self.contextMax = contextMax
        self.contextPercent = contextPercent
    }

    /// Whether this snapshot can drive the context meter (a real gauge).
    public var hasContextGauge: Bool {
        contextMax != nil && contextMax! > 0 && contextPercent != nil
    }
}

/// One `session.context_breakdown` category row.
public struct ContextBreakdownCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let tokens: Int

    public init(id: String, label: String, tokens: Int) {
        self.id = id
        self.label = label
        self.tokens = tokens
    }
}

/// `session.context_breakdown` result.
public struct ContextBreakdown: Hashable, Sendable {
    public let categories: [ContextBreakdownCategory]
    public let contextMax: Int
    public let contextPercent: Int
    public let contextUsed: Int
    public let estimatedTotal: Int
    public let model: String

    public init(
        categories: [ContextBreakdownCategory],
        contextMax: Int = 0,
        contextPercent: Int = 0,
        contextUsed: Int = 0,
        estimatedTotal: Int = 0,
        model: String = ""
    ) {
        self.categories = categories
        self.contextMax = contextMax
        self.contextPercent = contextPercent
        self.contextUsed = contextUsed
        self.estimatedTotal = estimatedTotal
        self.model = model
    }
}

/// Context-meter severity thresholds (plan Task 5): normal <70%, warn
/// 70–90%, alert >90%.
public enum ContextMeterLevel: Hashable, Sendable {
    case normal
    case warn
    case alert

    /// Classify a context percent (clamped 0...100).
    public static func level(forPercent percent: Int) -> ContextMeterLevel {
        let clamped = max(0, min(100, percent))
        if clamped > 90 { return .alert }
        if clamped >= 70 { return .warn }
        return .normal
    }
}

/// R9-T2/T3/T4 seam: model picker, usage/context reads, steer/rename/fork.
/// Lives in FleetCore so FleetUI never imports FleetNetworking (M0 guard);
/// the concrete `GatewayConversationToolingClient` is injected at the
/// composition root.
///
/// Selection policy is enforced STRUCTURALLY: this seam exposes NO method
/// that writes the model to config — the only write path for a model choice
/// is `session.create {model, provider}` (the per-session override,
/// methods_session.py:50-53). `config.set` is not part of this seam.
public protocol ConversationToolingProviding: Sendable {
    /// `model.options` flattened into selectable choices. The sticky-local
    /// rule: the CALLER holds the selection (per-device) and rides it on
    /// `session.create`; this read never mutates anything.
    /// - Parameter sessionID: the open runtime session id when one exists
    ///   (layered agent state — methods_complete.py:476-487), else nil.
    func modelChoices(sessionID: String?) async throws -> [ModelChoice]

    /// `session.usage` — the token/context snapshot for the meter.
    func usage(sessionID: String) async throws -> SessionUsageSnapshot

    /// `session.context_breakdown` — per-category tokens for the meter's
    /// detail sheet.
    func contextBreakdown(sessionID: String) async throws -> ContextBreakdown

    /// `session.steer {session_id, text}` — inject guidance into the running
    /// turn without interrupting it.
    /// - Returns: true when the gateway queued the steer (`status == "queued"`).
    func steer(sessionID: String, text: String) async throws -> Bool

    /// `session.title {session_id, title}` — rename the session.
    /// - Returns: the resolved (server-confirmed) title.
    func renameSession(sessionID: String, title: String) async throws -> String

    /// `session.branch {session_id, name?}` — fork the session's visible
    /// history into a new session.
    /// - Returns: the new conversation session (same projection as
    ///   create/resume; `sessionID` is the NEW runtime id to resume).
    func branchSession(sessionID: String, name: String?) async throws -> ConversationSession
}

/// Sessions whose concrete type carries a conversation-tooling seam.
/// Mirrors `ApprovalsCapable`: the UI layer resolves the seam with ONE cast
/// at build time (`session as? ConversationToolingCapable`) — deliberately
/// NOT a same-named extension property on `ConversationSessionProviding`
/// (an extension member named identically to a sub-protocol requirement
/// recurses through swift_dynamicCast; see the ApprovalsCapable note).
public protocol ConversationToolingCapable: ConversationSessionProviding {
    /// Model picker + usage/context reads + steer/rename/fork over the
    /// session's transport.
    var tooling: any ConversationToolingProviding { get }
}

/// Fail-soft default for sessions without the tooling seam surfaces: every
/// read throws, and the UI feature-detects on the seam's PRESENCE (nil cast)
/// rather than catching — so this type only exists for direct injections
/// that need an explicit "unsupported" implementation.
public struct UnsupportedConversationTooling: ConversationToolingProviding {
    public init() {}

    public func modelChoices(sessionID: String?) async throws -> [ModelChoice] {
        throw ConversationError.notConnected
    }

    public func usage(sessionID: String) async throws -> SessionUsageSnapshot {
        throw ConversationError.notConnected
    }

    public func contextBreakdown(sessionID: String) async throws -> ContextBreakdown {
        throw ConversationError.notConnected
    }

    public func steer(sessionID: String, text: String) async throws -> Bool {
        throw ConversationError.notConnected
    }

    public func renameSession(sessionID: String, title: String) async throws -> String {
        throw ConversationError.notConnected
    }

    public func branchSession(sessionID: String, name: String?) async throws -> ConversationSession {
        throw ConversationError.notConnected
    }
}
