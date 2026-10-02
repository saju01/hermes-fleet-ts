import XCTest
import FleetCore
@testable import FleetNetworking

/// OPTIONAL live lane (skipped unless `HERMES_FLEET_LIVE_DISPLAY_URL` and
/// `HERMES_FLEET_LIVE_DISPLAY_TOKEN` are set): a real `display.observe` →
/// `/api/display/ws` → RFB 3.8 handshake → first framebuffer update →
/// lease acquire/release round-trip against a running Hermes Bot Desktop.
/// Never part of the deterministic gate; no endpoint or credential is stored.
final class LiveDisplayRoundTripTests: XCTestCase {

    private struct LoopbackToken: AuthenticationProviding {
        let token: String
        func authenticate() async throws -> ConnectionAuthentication { .loopbackToken(StoredToken(rawValue: token)) }
    }

    func testLiveObserveStreamAndLeaseRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["HERMES_FLEET_LIVE_DISPLAY_URL"], let base = URL(string: raw),
              let token = env["HERMES_FLEET_LIVE_DISPLAY_TOKEN"], !token.isEmpty else {
            throw XCTSkip("live display lane not configured")
        }
        let transport = GatewayWebSocketTransport(baseURL: base, authentication: LoopbackToken(token: token))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let display = GatewayDisplayClient(transport: transport)

        let status = try await display.status(profile: nil)
        XCTAssertTrue(status.supported)
        XCTAssertTrue(status.running, "start the desktop (display.start) before this lane")

        let observation = try await display.observe(profile: nil, viewerID: nil)
        let stream = try await display.openStream(observation)
        var rfb = RFBClientSession()
        var ready: (Int, Int)?
        var updates = 0
        let deadline = Date().addingTimeInterval(20)
        while updates == 0, Date() < deadline {
            let chunk = try await stream.receive()
            let (events, outbound) = try rfb.receive(chunk)
            if !outbound.isEmpty { try await stream.send(outbound) }
            for event in events {
                if case .ready(let w, let h, _) = event { ready = (w, h) }
                if case .framebufferUpdated = event { updates += 1 }
            }
        }
        XCTAssertNotNil(ready, "RFB 3.8 / None handshake completed through the bridge")
        XCTAssertGreaterThan(updates, 0, "at least one framebuffer update decoded")
        let nonBlack = stride(from: 0, to: rfb.framebuffer.pixels.count, by: 4 * 997)
            .contains { rfb.framebuffer.pixels[$0] != 0 || rfb.framebuffer.pixels[$0 + 1] != 0 || rfb.framebuffer.pixels[$0 + 2] != 0 }
        print("LIVE: desktop \(ready.map { "\($0.0)x\($0.1)" } ?? "?") updates=\(updates) nonBlackSample=\(nonBlack)")

        // Take control → pointer move → hand back (same connection that observed).
        let acquired = try await display.acquireLease(profile: nil, viewerID: observation.viewerID, reason: "fleet live lane")
        XCTAssertTrue(acquired.isHeld(by: observation.viewerID), "viewer_hash identifies this viewer as holder")
        try await stream.send(RFBClientSession.pointerEvent(x: 10, y: 10, buttons: 0))
        let thumbWhileHeld = try await display.thumbnail(profile: nil)
        XCTAssertNotNil(thumbWhileHeld.suppressed, "thumbnail is withheld while a human holds")
        let released = try await display.releaseLease(profile: nil, viewerID: observation.viewerID)
        XCTAssertEqual(released.holder, .agent)
        print("LIVE: lease epochs acquire=\(acquired.epoch) release=\(released.epoch) suppressed=\(thumbWhileHeld.suppressed ?? "nil")")
        await stream.close()

        // The ticket is single-use: replaying it must close with 4401.
        let replay = try await display.openStream(observation)
        do {
            _ = try await replay.receive()
            XCTFail("a consumed ticket must not stream")
        } catch let error as BotDisplayError {
            XCTAssertEqual(error, .streamClosed(code: DisplayCloseCode.badTicket))
        }
    }
}
