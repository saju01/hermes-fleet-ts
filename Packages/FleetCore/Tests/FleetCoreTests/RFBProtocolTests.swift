import XCTest
@testable import FleetCore

/// Simple mode: the native RFB client parser (RFC 6143, RFB 3.8, security
/// None, Raw + CopyRect + DesktopSize) against synthetic server bytes.
final class RFBProtocolTests: XCTestCase {

    private func handshake(_ s: inout RFBClientSession, width: Int = 4, height: Int = 3) throws -> [RFBClientSession.Event] {
        var out = try s.receive(RFBServerFixture.version)
        XCTAssertEqual(out.outbound, Data("RFB 003.008\n".utf8))
        out = try s.receive(RFBServerFixture.securityTypes([1]))
        XCTAssertEqual(out.outbound, Data([1]), "chooses security None")
        out = try s.receive(RFBServerFixture.securityResultOK())
        XCTAssertEqual(out.outbound, Data([1]), "ClientInit shared=1")
        out = try s.receive(RFBServerFixture.serverInit(width: width, height: height, name: "bot"))
        return out.events
    }

    func testHandshakeMatchesTheBridgeFilterFixedSizeClientHandshake() throws {
        // rfb_filter.py frames exactly 12 + 1 + 1 client bytes before parsing
        // messages; the client must send exactly that, then valid messages.
        var s = RFBClientSession()
        var sent = Data()
        sent += try s.receive(RFBServerFixture.version).outbound
        sent += try s.receive(RFBServerFixture.securityTypes([1]) + RFBServerFixture.securityResultOK()).outbound
        XCTAssertEqual(sent.count, 14)
        let tail = try s.receive(RFBServerFixture.serverInit(width: 8, height: 8, name: "x"))
        XCTAssertEqual(tail.events, [.ready(width: 8, height: 8, name: "x")])
        // SetPixelFormat(20) + SetEncodings(4 + 4*3) + FBUpdateRequest(10)
        XCTAssertEqual(tail.outbound.count, 20 + 16 + 10)
        XCTAssertEqual(tail.outbound.first, 0)
        XCTAssertEqual(tail.outbound[20], 2)
        XCTAssertEqual(tail.outbound[36], 3)
        XCTAssertEqual(s.stage, .normal)
    }

    func testHandshakeToleratesArbitraryChunking() throws {
        var s = RFBClientSession()
        let stream = RFBServerFixture.version + RFBServerFixture.securityTypes([2, 1])
            + RFBServerFixture.securityResultOK() + RFBServerFixture.serverInit(width: 2, height: 2, name: "desk")
        var events: [RFBClientSession.Event] = []
        for byte in stream { events += try s.receive(Data([byte])).events }
        XCTAssertEqual(events, [.ready(width: 2, height: 2, name: "desk")])
    }

    func testRejectsOldProtocolAndMissingNoneSecurity() {
        var a = RFBClientSession()
        XCTAssertThrowsError(try a.receive(Data("RFB 003.003\n".utf8)))
        XCTAssertEqual(a.stage, .failed)
        var b = RFBClientSession()
        _ = try? b.receive(RFBServerFixture.version)
        XCTAssertThrowsError(try b.receive(RFBServerFixture.securityTypes([2]))) { error in
            XCTAssertEqual(error as? RFBError, .noSupportedSecurity([2]))
        }
    }

    func testSecurityFailureReasonSurfaces() throws {
        var s = RFBClientSession()
        _ = try s.receive(RFBServerFixture.version)
        var failure = Data([0])
        failure.appendU32(4); failure.append(Data("nope".utf8))
        XCTAssertThrowsError(try s.receive(failure)) { error in
            XCTAssertEqual(error as? RFBError, .securityFailed("nope"))
        }
    }

    func testRawRectPaintsFramebufferAndRequestsIncrementalUpdate() throws {
        var s = RFBClientSession()
        _ = try handshake(&s, width: 4, height: 3)
        let px: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0]
        let out = try s.receive(RFBServerFixture.framebufferUpdate([.raw(x: 1, y: 2, width: 2, height: 1, bgrx: px)]))
        XCTAssertEqual(out.events, [.framebufferUpdated(rects: 1)])
        XCTAssertEqual(s.framebuffer.pixel(x: 1, y: 2), [1, 2, 3, 0])
        XCTAssertEqual(s.framebuffer.pixel(x: 2, y: 2), [4, 5, 6, 0])
        XCTAssertEqual(s.framebuffer.pixel(x: 0, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(out.outbound, RFBClientSession.framebufferUpdateRequest(incremental: true, width: 4, height: 3))
    }

    func testCopyRectCopiesIncludingOverlap() throws {
        var s = RFBClientSession()
        _ = try handshake(&s, width: 3, height: 3)
        var px = [UInt8]()
        for i in 0..<9 { px += [UInt8(i), 0, 0, 0] }
        _ = try s.receive(RFBServerFixture.framebufferUpdate([.raw(x: 0, y: 0, width: 3, height: 3, bgrx: px)]))
        // Shift rows 0-1 down by one (overlapping source/destination).
        _ = try s.receive(RFBServerFixture.framebufferUpdate([.copy(x: 0, y: 1, width: 3, height: 2, sourceX: 0, sourceY: 0)]))
        XCTAssertEqual((0..<3).map { s.framebuffer.pixel(x: $0, y: 1)[0] }, [0, 1, 2])
        XCTAssertEqual((0..<3).map { s.framebuffer.pixel(x: $0, y: 2)[0] }, [3, 4, 5])
        XCTAssertEqual(s.framebuffer.pixel(x: 0, y: 0)[0], 0)
    }

    func testUpdateSplitAcrossChunksAppliesOnce() throws {
        var s = RFBClientSession()
        _ = try handshake(&s, width: 2, height: 1)
        let update = RFBServerFixture.framebufferUpdate([.raw(x: 0, y: 0, width: 2, height: 1, bgrx: [9, 9, 9, 0, 8, 8, 8, 0])])
        let first = try s.receive(update.prefix(7))
        XCTAssertTrue(first.events.isEmpty)
        let rest = try s.receive(update.dropFirst(7))
        XCTAssertEqual(rest.events, [.framebufferUpdated(rects: 1)])
        XCTAssertEqual(s.framebuffer.pixel(x: 1, y: 0), [8, 8, 8, 0])
    }

    func testDesktopSizeResizesAndOutOfBoundsRectFailsClosed() throws {
        var s = RFBClientSession()
        _ = try handshake(&s, width: 2, height: 2)
        let out = try s.receive(RFBServerFixture.framebufferUpdate([.desktopSize(width: 5, height: 4)]))
        XCTAssertEqual(out.events, [.resized(width: 5, height: 4), .framebufferUpdated(rects: 1)])
        XCTAssertEqual(s.framebuffer.width, 5)
        XCTAssertThrowsError(try s.receive(RFBServerFixture.framebufferUpdate(
            [.copy(x: 4, y: 3, width: 2, height: 2, sourceX: 0, sourceY: 0)])))
    }

    func testBellCutTextAndUnknownMessage() throws {
        var s = RFBClientSession()
        _ = try handshake(&s)
        var cut = Data([3, 0, 0, 0]); cut.appendU32(2); cut.append(Data("hi".utf8))
        XCTAssertEqual(try s.receive(Data([2]) + cut).events, [.bell, .serverCutText("hi")])
        XCTAssertThrowsError(try s.receive(Data([77]))) { XCTAssertEqual($0 as? RFBError, .unknownMessage(77)) }
    }

    func testUnsupportedEncodingFailsClosed() throws {
        var s = RFBClientSession()
        _ = try handshake(&s)
        var d = Data([0, 0]); d.appendU16(1); d.appendRectHeader(0, 0, 1, 1, 16) // ZRLE never advertised
        XCTAssertThrowsError(try s.receive(d)) { XCTAssertEqual($0 as? RFBError, .unsupportedEncoding(16)) }
    }

    func testClientMessageEncodingsMatchFilterFraming() {
        // Lengths the bridge filter frames by type (rfb_filter.py _FIXED).
        XCTAssertEqual(RFBClientSession.pointerEvent(x: 10, y: 20, buttons: 1), Data([5, 1, 0, 10, 0, 20]))
        XCTAssertEqual(RFBClientSession.keyEvent(keysym: 0x61, down: true), Data([4, 1, 0, 0, 0, 0, 0, 0x61]))
        XCTAssertEqual(RFBClientSession.setPixelFormatBGRX().count, 20)
        XCTAssertEqual(RFBClientSession.framebufferUpdateRequest(incremental: false, width: 1, height: 1).count, 10)
        XCTAssertEqual(RFBClientSession.pointerEvent(x: -5, y: 70000, buttons: 0), Data([5, 0, 0, 0, 0xff, 0xff]))
    }

    func testKeysymMapping() {
        XCTAssertEqual(RFBKeysym.forCharacter("a"), [0x61])
        XCTAssertEqual(RFBKeysym.forCharacter("\n"), [RFBKeysym.returnKey])
        XCTAssertEqual(RFBKeysym.forCharacter("é"), [0xe9])
        XCTAssertEqual(RFBKeysym.forCharacter("€"), [0x0100_20ac])
    }
}
