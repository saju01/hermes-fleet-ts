import XCTest
import FleetCore
@testable import FleetNetworking

/// Simple mode: `GatewayDisplayClient` wire shapes (tui_gateway/contracts/
/// display.py) against a recording RPC double and a fake socket factory.
final class GatewayDisplayClientTests: XCTestCase {

    private final class RecordingRPC: DisplayRPCRequesting, @unchecked Sendable {
        let lock = NSLock()
        var calls: [(String, JSONValue?)] = []
        var responder: (String) throws -> JSONValue
        init(_ responder: @escaping (String) throws -> JSONValue) { self.responder = responder }
        func request(method: String, params: JSONValue?) async throws -> JSONValue {
            lock.withLock { calls.append((method, params)) }
            return try responder(method)
        }
    }

    private final class FakeSession: WebSocketSession, @unchecked Sendable {
        var inbound: [WebSocketMessage]
        var sent: [WebSocketMessage] = []
        var closeCode: Int?
        init(_ inbound: [WebSocketMessage], closeCode: Int?) { self.inbound = inbound; self.closeCode = closeCode }
        func open() async throws {}
        func receive() async throws -> WebSocketMessage {
            if inbound.isEmpty { throw URLError(.networkConnectionLost) }
            return inbound.removeFirst()
        }
        func send(_ message: WebSocketMessage) async throws { sent.append(message) }
        func close(code: Int, reason: String?) async {}
        var lastCloseCode: Int? { inbound.isEmpty ? closeCode : nil }
    }

    private final class FakeFactory: WebSocketSessionFactory, @unchecked Sendable {
        var urls: [URL] = []
        let session: FakeSession
        init(_ session: FakeSession) { self.session = session }
        func makeSession(url: URL) -> any WebSocketSession { urls.append(url); return session }
    }

    private static func status(lease: [String: Any] = ["holder": "agent", "since": 1.0, "epoch": 1]) -> [String: Any] {
        ["profile": "default", "supported": true, "installed": true, "missing": [], "running": true,
         "geometry": "1280x800", "browser": "chromium", "lease": lease, "profile_key": "k"]
    }

    private static func json(_ object: Any) -> JSONValue { JSONValue(object) }

    func testObserveSendsProfileAndViewerAndDecodesTicket() async throws {
        let rpc = RecordingRPC { _ in
            Self.json(Self.status().merging(["ticket": "t-1", "path": "/api/display/ws", "viewer_id": "v-1"]) { $1 })
        }
        let client = GatewayDisplayClient(rpc: rpc, baseURL: URL(string: "https://gw.example.invalid")!,
                                          sessionFactory: FakeFactory(FakeSession([], closeCode: nil)))
        let obs = try await client.observe(profile: "default", viewerID: "v-0")
        XCTAssertEqual(rpc.calls.first?.0, "display.observe")
        XCTAssertEqual(rpc.calls.first?.1?["profile"]?.stringValue, "default")
        XCTAssertEqual(rpc.calls.first?.1?["viewer_id"]?.stringValue, "v-0")
        XCTAssertEqual(obs.ticket, "t-1")
        XCTAssertEqual(obs.viewerID, "v-1")
        XCTAssertTrue(obs.status.running)
        XCTAssertEqual(obs.status.lease.holder, .agent)
    }

    func testObserveWithoutViewerOmitsTheKeyAndRejectsMissingTicket() async {
        let rpc = RecordingRPC { _ in Self.json(Self.status()) }
        let client = GatewayDisplayClient(rpc: rpc, baseURL: URL(string: "http://gw.example.invalid")!,
                                          sessionFactory: FakeFactory(FakeSession([], closeCode: nil)))
        do {
            _ = try await client.observe(profile: nil, viewerID: nil)
            XCTFail("missing ticket must throw")
        } catch {}
        XCTAssertNil(rpc.calls.first?.1?["viewer_id"])
        XCTAssertNil(rpc.calls.first?.1?["profile"])
    }

    func testLeaseAcquireReleaseShapes() async throws {
        let hash = BotDisplayViewerHash.hash("v-1")
        let rpc = RecordingRPC { method in
            method == "display.lease.acquire"
                ? Self.json(["lease": ["holder": "human", "viewer_id": NSNull(), "viewer_hash": hash, "since": 2.0, "epoch": 4]])
                : Self.json(["lease": ["holder": "agent", "since": 3.0, "epoch": 5]])
        }
        let client = GatewayDisplayClient(rpc: rpc, baseURL: URL(string: "http://gw.example.invalid")!,
                                          sessionFactory: FakeFactory(FakeSession([], closeCode: nil)))
        let acquired = try await client.acquireLease(profile: "default", viewerID: "v-1", reason: "takeover")
        XCTAssertTrue(acquired.isHeld(by: "v-1"))
        XCTAssertEqual(acquired.epoch, 4)
        XCTAssertEqual(rpc.calls[0].1?["viewer_id"]?.stringValue, "v-1")
        XCTAssertEqual(rpc.calls[0].1?["reason"]?.stringValue, "takeover")
        let released = try await client.releaseLease(profile: "default", viewerID: "v-1")
        XCTAssertEqual(released.holder, .agent)
        XCTAssertEqual(rpc.calls[1].0, "display.lease.release")
        XCTAssertNil(rpc.calls[1].1?["force"], "never force-release another viewer")
    }

    func testThumbnailSuppressedWhileHumanHolds() async throws {
        let rpc = RecordingRPC { _ in Self.json(["data_url": NSNull(), "suppressed": "human"]) }
        let client = GatewayDisplayClient(rpc: rpc, baseURL: URL(string: "http://gw.example.invalid")!,
                                          sessionFactory: FakeFactory(FakeSession([], closeCode: nil)))
        let thumb = try await client.thumbnail(profile: nil)
        XCTAssertNil(thumb.imageData)
        XCTAssertEqual(thumb.suppressed, "human")
    }

    func testRPCErrorMapsToDisplayError() async {
        let rpc = RecordingRPC { _ in throw JSONRPCError(code: 5300, message: "Bot Desktop is not running") }
        let client = GatewayDisplayClient(rpc: rpc, baseURL: URL(string: "http://gw.example.invalid")!,
                                          sessionFactory: FakeFactory(FakeSession([], closeCode: nil)))
        do {
            _ = try await client.status(profile: nil)
            XCTFail("expected error")
        } catch let error as BotDisplayError {
            if case .rpcFailed = error {} else { XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    func testStreamURLCarriesTicketOnDisplayPathWithWSScheme() {
        let obs = DisplayObservation(ticket: "t/x+y", path: "/api/display/ws", viewerID: "v",
                                     status: DisplayStatusSnapshot(supported: true, installed: true, running: true))
        let https = GatewayDisplayClient.streamURL(base: URL(string: "https://gw.example.invalid:9119/ignored?a=1")!, observation: obs)
        XCTAssertEqual(https?.scheme, "wss")
        XCTAssertEqual(https?.path, "/api/display/ws")
        XCTAssertEqual(URLComponents(url: https!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "display_ticket", value: "t/x+y")])
        XCTAssertEqual(GatewayDisplayClient.streamURL(base: URL(string: "http://h:1")!, observation: obs)?.scheme, "ws")
        XCTAssertNil(GatewayDisplayClient.streamURL(base: URL(string: "ftp://h")!, observation: obs))
    }

    func testStreamPipesBinaryAndSurfacesCloseCode() async throws {
        let session = FakeSession([.data(Data("RFB 003.008\n".utf8))], closeCode: DisplayCloseCode.controlTaken)
        let factory = FakeFactory(session)
        let client = GatewayDisplayClient(rpc: RecordingRPC { _ in .null }, baseURL: URL(string: "http://gw.example.invalid")!,
                                          sessionFactory: factory)
        let obs = DisplayObservation(ticket: "t", path: "/api/display/ws", viewerID: "v",
                                     status: DisplayStatusSnapshot(supported: true, installed: true, running: true))
        let stream = try await client.openStream(obs)
        XCTAssertEqual(factory.urls.first?.query, "display_ticket=t")
        let chunk = try await stream.receive()
        XCTAssertEqual(chunk, Data("RFB 003.008\n".utf8))
        try await stream.send(Data([1]))
        XCTAssertEqual(session.sent, [.data(Data([1]))], "RFB bytes go out as binary frames")
        do {
            _ = try await stream.receive()
            XCTFail("closed")
        } catch let error as BotDisplayError {
            XCTAssertEqual(error, .streamClosed(code: DisplayCloseCode.controlTaken))
        }
    }

    func testTextFrameIsAProtocolViolation() async throws {
        let session = FakeSession([.text("nope")], closeCode: nil)
        let client = GatewayDisplayClient(rpc: RecordingRPC { _ in .null }, baseURL: URL(string: "http://gw.example.invalid")!,
                                          sessionFactory: FakeFactory(session))
        let stream = try await client.openStream(DisplayObservation(
            ticket: "t", path: "/api/display/ws", viewerID: "v",
            status: DisplayStatusSnapshot(supported: true, installed: true, running: true)))
        do { _ = try await stream.receive(); XCTFail() } catch let e as BotDisplayError {
            XCTAssertEqual(e, .streamClosed(code: 1003))
        }
    }

    func testModelOptionsCapabilitiesDecodeIntoChoices() {
        let result = JSONValue([
            "providers": [["slug": "anthropic", "name": "Anthropic", "is_current": true,
                           "models": ["opus", "haiku"],
                           "capabilities": ["opus": ["fast": false, "reasoning": true, "can_disable_reasoning": false],
                                            "haiku": ["fast": true, "reasoning": false]]]],
            "model": "opus", "provider": "anthropic",
        ] as [String: Any])
        let choices = GatewayConversationToolingClient.decodeModelChoices(result)
        let opus = choices.first { $0.model == "opus" }
        XCTAssertEqual(opus?.supportsReasoning, true)
        XCTAssertEqual(opus?.canDisableReasoning, false)
        XCTAssertFalse(opus?.availableEfforts.contains(.none) ?? true)
        XCTAssertEqual(choices.first { $0.model == "haiku" }?.availableEfforts, [])
    }
}
