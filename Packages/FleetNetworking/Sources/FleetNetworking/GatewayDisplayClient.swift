import Foundation
import FleetCore

/// The JSON-RPC surface `GatewayDisplayClient` needs (the shared transport
/// conforms; tests inject a recorder).
public protocol DisplayRPCRequesting: Sendable {
    func request(method: String, params: JSONValue?) async throws -> JSONValue
}

extension GatewayWebSocketTransport: DisplayRPCRequesting {
    /// The gateway origin this transport dials (display sockets share it).
    public nonisolated var displayBaseURL: URL { baseURL }
    /// The transport's socket factory (TLS pinning / embedded tailnet routing
    /// apply to the display socket exactly as to `/api/ws`).
    public nonisolated var displaySessionFactory: any WebSocketSessionFactory { sessionFactory }
}

/// Concrete Bot Desktop client (`display.*` + the RFB socket).
///
/// MUST ride the conversation session's own transport: the gateway mints
/// viewer ids per connection (`_minted_for_this_connection`) and refuses a
/// `display.lease.*` call naming an id another socket minted.
public struct GatewayDisplayClient: BotDisplayProviding {
    private let rpc: any DisplayRPCRequesting
    private let baseURL: URL
    private let sessionFactory: any WebSocketSessionFactory

    public init(rpc: any DisplayRPCRequesting, baseURL: URL, sessionFactory: any WebSocketSessionFactory) {
        self.rpc = rpc
        self.baseURL = baseURL
        self.sessionFactory = sessionFactory
    }

    public init(transport: GatewayWebSocketTransport) {
        self.init(rpc: transport, baseURL: transport.displayBaseURL, sessionFactory: transport.displaySessionFactory)
    }

    public func status(profile: String?) async throws -> DisplayStatusSnapshot {
        try Self.decodeStatus(await call("display.status", profileParams(profile)))
    }

    public func thumbnail(profile: String?) async throws -> DisplayThumbnail {
        let result = try await call("display.thumbnail", profileParams(profile))
        return DisplayThumbnail(
            imageData: DisplayThumbnail.decodeDataURL(result["data_url"]?.stringValue),
            suppressed: result["suppressed"]?.stringValue)
    }

    public func observe(profile: String?, viewerID: String?) async throws -> DisplayObservation {
        var params = profileParams(profile)
        if let viewerID, !viewerID.isEmpty { params["viewer_id"] = .string(viewerID) }
        let result = try await call("display.observe", params)
        guard let ticket = result["ticket"]?.stringValue, !ticket.isEmpty,
              let viewer = result["viewer_id"]?.stringValue, !viewer.isEmpty else {
            throw BotDisplayError.rpcFailed("display.observe result missing ticket/viewer_id")
        }
        let path = result["path"]?.stringValue ?? "/api/display/ws"
        guard path.hasPrefix("/api/") else {
            throw BotDisplayError.rpcFailed("unexpected display path")
        }
        return DisplayObservation(ticket: ticket, path: path, viewerID: viewer, status: try Self.decodeStatus(result))
    }

    public func acquireLease(profile: String?, viewerID: String, reason: String?) async throws -> DisplayLease {
        var params = profileParams(profile)
        params["viewer_id"] = .string(viewerID)
        if let reason { params["reason"] = .string(reason) }
        return try Self.decodeLease(await call("display.lease.acquire", params)["lease"])
    }

    public func releaseLease(profile: String?, viewerID: String) async throws -> DisplayLease {
        var params = profileParams(profile)
        params["viewer_id"] = .string(viewerID)
        return try Self.decodeLease(await call("display.lease.release", params)["lease"])
    }

    public func openStream(_ observation: DisplayObservation) async throws -> any DisplayByteStream {
        guard let url = Self.streamURL(base: baseURL, observation: observation) else {
            throw BotDisplayError.rpcFailed("cannot build display socket URL")
        }
        let session = sessionFactory.makeSession(url: url)
        try await session.open()
        return WebSocketDisplayStream(session: session)
    }

    // MARK: helpers

    private func profileParams(_ profile: String?) -> [String: JSONValue] {
        guard let profile, !profile.isEmpty else { return [:] }
        return ["profile": .string(profile)]
    }

    private func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        do {
            return try await rpc.request(method: method, params: .object(params))
        } catch let error as JSONRPCError {
            throw BotDisplayError.rpcFailed(Redaction.safeText(error.message))
        } catch let error as TransportError {
            if case .invalidState = error { throw BotDisplayError.notConnected }
            throw BotDisplayError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    /// `ws(s)://host/api/display/ws?display_ticket=…` — the ticket rides the
    /// query by gateway design (single-use, 30 s). Never log this URL.
    public static func streamURL(base: URL, observation: DisplayObservation) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch c.scheme?.lowercased() {
        case "http": c.scheme = "ws"
        case "https": c.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        c.path = observation.path
        c.queryItems = [URLQueryItem(name: "display_ticket", value: observation.ticket)]
        return c.url
    }

    static func decodeLease(_ value: JSONValue?) throws -> DisplayLease {
        guard let o = value?.objectValue,
              let holder = o["holder"]?.stringValue.flatMap(DisplayLeaseHolder.init(rawValue:)) else {
            throw BotDisplayError.rpcFailed("lease missing holder")
        }
        return DisplayLease(
            holder: holder,
            viewerHash: o["viewer_hash"]?.stringValue,
            epoch: o["epoch"]?.numberValue.map(Int.init) ?? 0)
    }

    static func decodeStatus(_ result: JSONValue) throws -> DisplayStatusSnapshot {
        let lease = (try? decodeLease(result["lease"])) ?? DisplayLease(holder: .agent)
        return DisplayStatusSnapshot(
            supported: result["supported"]?.boolValue ?? false,
            installed: result["installed"]?.boolValue ?? false,
            running: result["running"]?.boolValue ?? false,
            geometry: result["geometry"]?.stringValue ?? "",
            browser: result["browser"]?.stringValue,
            blocker: result["blocker"]?.stringValue,
            lease: lease)
    }
}

/// Binary RFB pipe over a `WebSocketSession`.
final class WebSocketDisplayStream: DisplayByteStream, @unchecked Sendable {
    private let session: any WebSocketSession

    init(session: any WebSocketSession) { self.session = session }

    func send(_ data: Data) async throws {
        try await session.send(.data(data))
    }

    func receive() async throws -> Data {
        do {
            switch try await session.receive() {
            case .data(let d): return d
            case .text: throw BotDisplayError.streamClosed(code: 1003) // RFB is binary
            }
        } catch let error as BotDisplayError {
            throw error
        } catch {
            throw BotDisplayError.streamClosed(code: session.lastCloseCode)
        }
    }

    func close() async {
        await session.close(code: 1000, reason: nil)
    }
}
