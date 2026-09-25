import Foundation

public enum EmbeddedTailnetState: String, Sendable {
    case stopped = "Stopped"
    case starting = "Starting"
    case needsLogin = "Sign in required"
    case needsApproval = "Device approval required"
    case running = "Connected"
    case failed = "Unavailable — retry or check enrollment"
}

/// Auth URL is transient UI-only data. Never persist or include it in diagnostics.
public struct EmbeddedTailnetSnapshot: Sendable {
    public var state: EmbeddedTailnetState
    public var enrollmentURL: URL?
    public init(state: EmbeddedTailnetState, enrollmentURL: URL? = nil) {
        self.state = state
        self.enrollmentURL = enrollmentURL
    }
}

public protocol EmbeddedTailnetManaging: Sendable {
    func start() async throws
    func login() async throws
    func stop() async throws
    func logout() async throws
    func suspend() async throws
    func resume() async throws
    func snapshot() async -> EmbeddedTailnetSnapshot
}

public extension EmbeddedTailnetManaging {
    func suspend() async throws {}
    func resume() async throws {}
}
