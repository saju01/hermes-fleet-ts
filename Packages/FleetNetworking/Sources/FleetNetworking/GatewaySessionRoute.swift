import Foundation
import Network
import FleetCore
import os

/// Allows each credential-bearing request to acquire the CURRENT node route.
/// A URLSession made before login must not permanently capture a dead proxy.
public protocol GatewayHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GatewayHTTPClient {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

/// Revocation boundary shared by all HTTP and WS sessions of one node generation.
public final class GatewaySessionLifetime: Sendable {
    private struct State: @unchecked Sendable {
        var active = true
        var sessions: [UUID: URLSession] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}
    public func register(_ session: URLSession) throws -> UUID {
        try state.withLock { state in
            guard state.active else { session.invalidateAndCancel(); throw EmbeddedTailnetError.notRunning }
            let id = UUID()
            state.sessions[id] = session
            return id
        }
    }
    public func remove(_ id: UUID) { _ = state.withLock { $0.sessions.removeValue(forKey: id) } }
    public func invalidate() {
        let sessions = state.withLock { state in
            state.active = false
            let sessions = Array(state.sessions.values)
            state.sessions.removeAll()
            return sessions
        }
        sessions.forEach { $0.invalidateAndCancel() }
    }
}

public struct GatewaySessionConfiguration: @unchecked Sendable {
    public let configuration: URLSessionConfiguration
    public let lifetime: GatewaySessionLifetime
    public init(configuration: URLSessionConfiguration, lifetime: GatewaySessionLifetime) {
        self.configuration = configuration
        self.lifetime = lifetime
    }
}

public struct GatewaySessionRoute: Sendable {
    public let endpoint: URL
    public let trustHandler: PinningTrustHandler?
    private let acquire: @Sendable () async throws -> GatewaySessionConfiguration
    public init(endpoint: URL, trustHandler: PinningTrustHandler? = nil,
                acquire: @escaping @Sendable () async throws -> GatewaySessionConfiguration) {
        self.endpoint = endpoint
        self.trustHandler = trustHandler
        self.acquire = acquire
    }
    public func configuration(for url: URL) async throws -> GatewaySessionConfiguration {
        try EmbeddedTailnetPolicy.validateRequest(url, endpoint: endpoint)
        try Task.checkCancellation()
        let lease = try await acquire()
        guard lease.configuration.proxyConfigurations.count == 1 else {
            throw EmbeddedTailnetError.unavailable
        }
        try Task.checkCancellation()
        return lease
    }
}

public struct RoutedGatewayHTTPClient: GatewayHTTPClient {
    let route: GatewaySessionRoute
    public init(route: GatewaySessionRoute) { self.route = route }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw EmbeddedTailnetError.invalidEndpoint }
        let lease = try await route.configuration(for: url)
        let delegate = URLSessionPinningDelegate(trustHandler: route.trustHandler, rejectRedirects: true)
        let session = URLSession(configuration: lease.configuration, delegate: delegate, delegateQueue: nil)
        let id = try lease.lifetime.register(session)
        defer { session.invalidateAndCancel(); lease.lifetime.remove(id) }
        return try await session.data(for: request)
    }
}

public struct RoutedWebSocketSessionFactory: WebSocketSessionFactory {
    let route: GatewaySessionRoute
    public init(route: GatewaySessionRoute) { self.route = route }
    public func makeSession(url: URL) -> any WebSocketSession { RoutedWebSocketSession(url: url, route: route) }
}

private actor RoutedWebSocketSession: WebSocketSession {
    let url: URL
    let route: GatewaySessionRoute
    var socket: URLSessionWebSocketSession?
    var closed = false
    nonisolated let closeCode = OSAllocatedUnfairLock<Int?>(initialState: nil)
    nonisolated var lastCloseCode: Int? { closeCode.withLock { $0 } }
    init(url: URL, route: GatewaySessionRoute) { self.url = url; self.route = route }
    func open() async throws {
        guard !closed, socket == nil else { throw EmbeddedTailnetError.notRunning }
        let lease = try await route.configuration(for: url)
        guard !closed else { throw CancellationError() }
        let created = URLSessionWebSocketSession(url: url, configuration: lease.configuration,
            trustHandler: route.trustHandler, rejectRedirects: true)
        try created.bindLifetime(lease.lifetime)
        socket = created
        try await created.open()
    }
    func receive() async throws -> WebSocketMessage {
        guard let socket, !closed else { throw EmbeddedTailnetError.notRunning }
        do { return try await socket.receive() }
        catch { closeCode.withLock { $0 = socket.lastCloseCode }; throw error }
    }
    func send(_ message: WebSocketMessage) async throws {
        guard let socket, !closed else { throw EmbeddedTailnetError.notRunning }
        try await socket.send(message)
    }
    func close(code: Int, reason: String?) async {
        closed = true
        closeCode.withLock { $0 = code }
        await socket?.close(code: code, reason: reason)
        socket = nil
    }
}
