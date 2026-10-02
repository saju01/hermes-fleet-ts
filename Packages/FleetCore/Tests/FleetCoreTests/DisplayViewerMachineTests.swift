import XCTest
@testable import FleetCore

/// Simple mode: Watch / Take control / Hand back state machine, close-code
/// handling (display.py 4000/4001/4401/4403), lease ownership via the
/// gateway viewer_hash, and the reasoning-effort capability gate.
final class DisplayViewerMachineTests: XCTestCase {

    private func held(_ id: String) -> DisplayLease {
        DisplayLease(holder: .human, viewerHash: BotDisplayViewerHash.hash(id), epoch: 2)
    }

    private func watching() -> DisplayViewerMachine {
        var m = DisplayViewerMachine()
        XCTAssertEqual(m.start(), [.observe(viewerID: nil)])
        XCTAssertEqual(m.observed(viewerID: "v1"), [.openStream])
        XCTAssertEqual(m.streamReady(), [])
        XCTAssertEqual(m.phase, .watching)
        return m
    }

    func testViewerHashMatchesGatewayPublicView() {
        // tools/bot_desktop/lease.py: sha256(viewer_id).hexdigest()[:12]
        XCTAssertEqual(BotDisplayViewerHash.hash("abc"), "ba7816bf8f01")
        XCTAssertTrue(held("v1").isHeld(by: "v1"))
        XCTAssertFalse(held("v1").isHeld(by: "v2"))
        XCTAssertFalse(DisplayLease(holder: .agent).isHeld(by: "v1"))
    }

    func testWatchTakeControlHandBack() {
        var m = watching()
        XCTAssertFalse(m.canSendInput)
        XCTAssertEqual(m.requestControl(), [.acquire(viewerID: "v1")])
        XCTAssertEqual(m.phase, .acquiring)
        XCTAssertFalse(m.canSendInput, "no input until the gateway confirms the lease")
        _ = m.leaseResult(held("v1"))
        XCTAssertEqual(m.phase, .controlling)
        XCTAssertTrue(m.canSendInput)
        XCTAssertEqual(m.requestHandBack(), [.release(viewerID: "v1")])
        XCTAssertFalse(m.canSendInput)
        _ = m.leaseResult(DisplayLease(holder: .agent, epoch: 3))
        XCTAssertEqual(m.phase, .watching)
    }

    func testAcquireGrantedToSomeoneElseStaysWatching() {
        var m = watching()
        _ = m.requestControl()
        _ = m.leaseResult(held("other"))
        XCTAssertEqual(m.phase, .watching)
        _ = m.requestControl()
        _ = m.leaseFailed()
        XCTAssertEqual(m.phase, .watching)
    }

    func testStartInControlAcquiresAfterStreamReady() {
        var m = DisplayViewerMachine()
        _ = m.start(takeControl: true)
        _ = m.observed(viewerID: "v9")
        XCTAssertEqual(m.streamReady(), [.acquire(viewerID: "v9")])
    }

    func testControlTakenDropsBackToWatchOnFreshTicketKeepingViewerID() {
        var m = watching()
        _ = m.requestControl(); _ = m.leaseResult(held("v1"))
        XCTAssertEqual(m.streamClosed(code: DisplayCloseCode.controlTaken), [.observe(viewerID: "v1")])
        XCTAssertEqual(m.phase, .observing)
        XCTAssertFalse(m.canSendInput)
        _ = m.observed(viewerID: "v1"); _ = m.streamReady()
        XCTAssertEqual(m.phase, .watching, "4000 never auto re-acquires")
    }

    func testBadTicketRetriesOnceThenEnds() {
        var m = DisplayViewerMachine()
        _ = m.start(); _ = m.observed(viewerID: "v1")
        XCTAssertEqual(m.streamClosed(code: DisplayCloseCode.badTicket), [.observe(viewerID: "v1")])
        _ = m.observed(viewerID: "v1")
        XCTAssertEqual(m.streamClosed(code: DisplayCloseCode.badTicket), [])
        XCTAssertEqual(m.phase, .ended(.ticketRejected))
    }

    func testTerminalCloseCodes() {
        var a = watching()
        _ = a.streamClosed(code: DisplayCloseCode.desktopGone)
        XCTAssertEqual(a.phase, .ended(.desktopGone))
        var b = watching()
        _ = b.streamClosed(code: DisplayCloseCode.notAllowed)
        XCTAssertEqual(b.phase, .ended(.notAllowed))
        var c = watching()
        _ = c.streamClosed(code: nil)
        if case .ended(.failed) = c.phase {} else { XCTFail("transport loss ends the viewer") }
        XCTAssertEqual(c.start(), [.observe(viewerID: "v1")], "restartable after ending")
    }

    func testCloseWhileControllingHandsBackFirst() {
        var m = watching()
        _ = m.requestControl(); _ = m.leaseResult(held("v1"))
        XCTAssertEqual(m.close(), [.release(viewerID: "v1"), .closeStream])
        XCTAssertEqual(m.phase, .ended(.closedByUser))
        XCTAssertEqual(m.streamClosed(code: 1000), [], "late close after user close is ignored")
    }

    func testCloseWhileWatchingOnlyClosesStream() {
        var m = watching()
        XCTAssertEqual(m.close(), [.closeStream])
    }

    func testThumbnailDataURLDecoding() {
        let data = Data([0xff, 0xd8, 0xff])
        XCTAssertEqual(DisplayThumbnail.decodeDataURL("data:image/jpeg;base64,\(data.base64EncodedString())"), data)
        XCTAssertNil(DisplayThumbnail.decodeDataURL(nil))
        XCTAssertNil(DisplayThumbnail.decodeDataURL("https://example.invalid/x.jpg"))
    }

    func testReasoningEffortAvailabilityFollowsCapabilities() {
        XCTAssertEqual(ReasoningEffort.available(reasoning: false, canDisableReasoning: nil), [])
        XCTAssertFalse(ReasoningEffort.available(reasoning: true, canDisableReasoning: false).contains(.none))
        XCTAssertEqual(ReasoningEffort.available(reasoning: nil, canDisableReasoning: nil), ReasoningEffort.allCases)
        // Wire values are the gateway's level strings (hermes_constants).
        XCTAssertTrue(ReasoningEffort.allCases.allSatisfy { !$0.rawValue.isEmpty && Int($0.rawValue) == nil })
    }
}
