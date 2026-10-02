import Foundation

/// Hermes thinking-effort levels as the gateway takes them on
/// `session.create {reasoning_effort}` (tui_gateway/contracts/sessions.py;
/// parsed by hermes_constants.parse_reasoning_effort). Strings, NOT token
/// budgets — the provider adapter maps a level to its own wire form.
public enum ReasoningEffort: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case none, low, medium, high, xhigh, max

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }

    /// Levels to offer for a model given its `model.options` capabilities.
    /// - `reasoning == false` → nothing (the model does not think).
    /// - `canDisableReasoning == false` → every level except `none`.
    /// - unknown capabilities (nil) → all levels; the gateway clamps.
    public static func available(reasoning: Bool?, canDisableReasoning: Bool?) -> [ReasoningEffort] {
        if reasoning == false { return [] }
        if canDisableReasoning == false { return allCases.filter { $0 != .none } }
        return allCases
    }
}

extension ConversationProviding {
    /// `session.create` with a per-session thinking effort. Conformers that
    /// predate the effort parameter fall back to the plain create (the
    /// gateway then inherits the profile's effort) — honest degradation,
    /// never a config write.
    public func createSession(
        title: String?,
        profile: String?,
        model: String?,
        provider: String?,
        reasoningEffort: ReasoningEffort?,
        cols: Int?
    ) async throws -> ConversationSession {
        if let effortCapable = self as? any ReasoningEffortCreating {
            return try await effortCapable.createSessionWithEffort(
                title: title, profile: profile, model: model, provider: provider,
                reasoningEffort: reasoningEffort, cols: cols)
        }
        return try await createSession(title: title, profile: profile, model: model, provider: provider, cols: cols)
    }
}

/// Conversation clients that can ride `reasoning_effort` on `session.create`.
public protocol ReasoningEffortCreating: ConversationProviding {
    func createSessionWithEffort(
        title: String?,
        profile: String?,
        model: String?,
        provider: String?,
        reasoningEffort: ReasoningEffort?,
        cols: Int?
    ) async throws -> ConversationSession
}
