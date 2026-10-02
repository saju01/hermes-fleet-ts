import Foundation

/// Native RFB (VNC) client protocol engine for Hermes Bot Desktop.
///
/// Wire ground truth (hermes-agent `tools/bot_desktop/rfb_filter.py`,
/// `hermes_cli/web_routers/display.py`): the gateway bridges raw RFB bytes
/// over a binary WebSocket at `/api/display/ws?display_ticket=…`. Xvnc runs
/// `-SecurityTypes None`; the bridge already authenticated the viewer via the
/// single-use ticket, and its client-stream filter frames a fixed-size
/// handshake (12-byte version + 1-byte security choice + 1-byte ClientInit)
/// before parsing client messages. Only RFB 3.8 with security type None (1)
/// is supported here.
///
/// Pure value type: feed server bytes with `receive(_:)`, send the returned
/// `outbound` bytes. No I/O, no clocks — deterministic and host-testable.
public struct RFBClientSession: Sendable {
    public enum Stage: Equatable, Sendable {
        case version, securityTypes, securityResult, serverInit, normal, failed
    }

    public enum Event: Equatable, Sendable {
        /// ServerInit parsed: the framebuffer exists from now on.
        case ready(width: Int, height: Int, name: String)
        /// One complete FramebufferUpdate was applied.
        case framebufferUpdated(rects: Int)
        case resized(width: Int, height: Int)
        case bell
        case serverCutText(String)
    }

    /// Encodings the client advertises (RFC 6143 §7.7).
    public static let encodingRaw: Int32 = 0
    public static let encodingCopyRect: Int32 = 1
    public static let encodingDesktopSize: Int32 = -223

    public private(set) var stage: Stage = .version
    public private(set) var framebuffer = RFBFramebuffer(width: 0, height: 0)
    public private(set) var desktopName = ""

    private var buffer: [UInt8] = []
    private var cursor = 0
    /// Remaining rectangles of an in-flight FramebufferUpdate (nil = idle).
    private var pendingRects: Int?
    private var appliedRects = 0

    public init() {}

    /// Feed server→client bytes. Returns protocol events and the bytes the
    /// client must send back (handshake replies, update requests).
    public mutating func receive(_ data: Data) throws -> (events: [Event], outbound: Data) {
        buffer.append(contentsOf: data)
        var events: [Event] = []
        var out = Data()
        do {
            while try step(&events, &out) {}
        } catch {
            stage = .failed
            throw error
        }
        compact()
        return (events, out)
    }

    // MARK: client → server encoders

    public static func pointerEvent(x: Int, y: Int, buttons: UInt8) -> Data {
        var d = Data([5, buttons])
        d.appendU16(UInt16(clamping: max(0, x)))
        d.appendU16(UInt16(clamping: max(0, y)))
        return d
    }

    public static func keyEvent(keysym: UInt32, down: Bool) -> Data {
        var d = Data([4, down ? 1 : 0, 0, 0])
        d.appendU32(keysym)
        return d
    }

    public static func framebufferUpdateRequest(incremental: Bool, x: Int = 0, y: Int = 0, width: Int, height: Int) -> Data {
        var d = Data([3, incremental ? 1 : 0])
        d.appendU16(UInt16(clamping: x)); d.appendU16(UInt16(clamping: y))
        d.appendU16(UInt16(clamping: width)); d.appendU16(UInt16(clamping: height))
        return d
    }

    /// SetPixelFormat: 32bpp, depth 24, little-endian true colour with
    /// R/G/B shifts 16/8/0, so each pixel lands in memory as B,G,R,X —
    /// directly drawable as a 32-bit little-endian skip-first bitmap.
    public static func setPixelFormatBGRX() -> Data {
        var d = Data([0, 0, 0, 0])
        d.append(contentsOf: [32, 24, 0, 1])
        d.appendU16(255); d.appendU16(255); d.appendU16(255)
        d.append(contentsOf: [16, 8, 0, 0, 0, 0])
        return d
    }

    public static func setEncodings(_ encodings: [Int32]) -> Data {
        var d = Data([2, 0])
        d.appendU16(UInt16(encodings.count))
        for e in encodings { d.appendU32(UInt32(bitPattern: e)) }
        return d
    }

    // MARK: parsing

    private var available: Int { buffer.count - cursor }

    private mutating func step(_ events: inout [Event], _ out: inout Data) throws -> Bool {
        switch stage {
        case .failed:
            return false
        case .version:
            guard available >= 12 else { return false }
            let bytes = take(12)
            guard let text = String(bytes: bytes, encoding: .ascii), text.hasPrefix("RFB ") else {
                throw RFBError.protocolVersion("not an RFB server")
            }
            let parts = text.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
            guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]),
                  major == 3, minor >= 8 else {
                throw RFBError.protocolVersion(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            out.append(contentsOf: Array("RFB 003.008\n".utf8))
            stage = .securityTypes
            return true
        case .securityTypes:
            guard available >= 1 else { return false }
            let count = Int(buffer[cursor])
            if count == 0 {
                guard let reason = try peekReason(at: cursor + 1) else { return false }
                cursor += 1 + 4 + reason.byteCount
                throw RFBError.securityFailed(reason.text)
            }
            guard available >= 1 + count else { return false }
            cursor += 1
            let types = take(count)
            guard types.contains(1) else { throw RFBError.noSupportedSecurity(types) }
            out.append(1) // None — the bridge already authenticated the ticket
            stage = .securityResult
            return true
        case .securityResult:
            guard available >= 4 else { return false }
            let status = readU32(at: cursor)
            if status != 0 {
                guard let reason = try peekReason(at: cursor + 4) else { return false }
                cursor += 4 + 4 + reason.byteCount
                throw RFBError.securityFailed(reason.text)
            }
            cursor += 4
            out.append(1) // ClientInit: shared (the bridge forces it anyway)
            stage = .serverInit
            return true
        case .serverInit:
            guard available >= 24 else { return false }
            let nameLength = Int(readU32(at: cursor + 20))
            guard nameLength <= 1 << 16 else { throw RFBError.malformed("desktop name too long") }
            guard available >= 24 + nameLength else { return false }
            let width = Int(readU16(at: cursor)), height = Int(readU16(at: cursor + 2))
            cursor += 24
            desktopName = String(decoding: take(nameLength), as: UTF8.self)
            framebuffer = RFBFramebuffer(width: width, height: height)
            out.append(Self.setPixelFormatBGRX())
            out.append(Self.setEncodings([Self.encodingRaw, Self.encodingCopyRect, Self.encodingDesktopSize]))
            out.append(Self.framebufferUpdateRequest(incremental: false, width: width, height: height))
            stage = .normal
            events.append(.ready(width: width, height: height, name: desktopName))
            return true
        case .normal:
            if pendingRects != nil { return try stepRect(&events, &out) }
            guard available >= 1 else { return false }
            switch buffer[cursor] {
            case 0: // FramebufferUpdate
                guard available >= 4 else { return false }
                let n = Int(readU16(at: cursor + 2))
                cursor += 4
                appliedRects = 0
                pendingRects = n
                if n == 0 { finishUpdate(&events, &out) }
                return true
            case 1: // SetColourMapEntries (unused in true colour; skip)
                guard available >= 6 else { return false }
                let n = Int(readU16(at: cursor + 4))
                guard available >= 6 + 6 * n else { return false }
                cursor += 6 + 6 * n
                return true
            case 2:
                cursor += 1
                events.append(.bell)
                return true
            case 3: // ServerCutText
                guard available >= 8 else { return false }
                let length = Int(Int32(bitPattern: readU32(at: cursor + 4)))
                guard length >= 0, length <= 1 << 20 else { throw RFBError.malformed("cut text length \(length)") }
                guard available >= 8 + length else { return false }
                cursor += 8
                events.append(.serverCutText(String(decoding: take(length), as: UTF8.self)))
                return true
            case let type:
                throw RFBError.unknownMessage(type)
            }
        }
    }

    private mutating func stepRect(_ events: inout [Event], _ out: inout Data) throws -> Bool {
        guard let remaining = pendingRects else { return false }
        if remaining == 0 { finishUpdate(&events, &out); return true }
        guard available >= 12 else { return false }
        let x = Int(readU16(at: cursor)), y = Int(readU16(at: cursor + 2))
        let w = Int(readU16(at: cursor + 4)), h = Int(readU16(at: cursor + 6))
        let encoding = Int32(bitPattern: readU32(at: cursor + 8))
        switch encoding {
        case Self.encodingRaw:
            let length = w * h * 4
            guard available >= 12 + length else { return false }
            cursor += 12
            try framebuffer.applyRaw(x: x, y: y, width: w, height: h, bytes: buffer, offset: cursor)
            cursor += length
        case Self.encodingCopyRect:
            guard available >= 16 else { return false }
            let sx = Int(readU16(at: cursor + 12)), sy = Int(readU16(at: cursor + 14))
            cursor += 16
            try framebuffer.applyCopyRect(x: x, y: y, width: w, height: h, sourceX: sx, sourceY: sy)
        case Self.encodingDesktopSize:
            cursor += 12
            framebuffer = RFBFramebuffer(width: w, height: h)
            events.append(.resized(width: w, height: h))
        default:
            throw RFBError.unsupportedEncoding(encoding)
        }
        appliedRects += 1
        pendingRects = remaining - 1
        if pendingRects == 0 { finishUpdate(&events, &out) }
        return true
    }

    private mutating func finishUpdate(_ events: inout [Event], _ out: inout Data) {
        pendingRects = nil
        events.append(.framebufferUpdated(rects: appliedRects))
        out.append(Self.framebufferUpdateRequest(
            incremental: true, width: framebuffer.width, height: framebuffer.height))
    }

    private func peekReason(at offset: Int) throws -> (text: String, byteCount: Int)? {
        guard buffer.count - offset >= 4 else { return nil }
        let length = Int(readU32(at: offset))
        guard length <= 1 << 16 else { throw RFBError.malformed("reason too long") }
        guard buffer.count - offset - 4 >= length else { return nil }
        let text = String(decoding: buffer[(offset + 4)..<(offset + 4 + length)], as: UTF8.self)
        return (text, length)
    }

    private mutating func take(_ n: Int) -> [UInt8] {
        let slice = Array(buffer[cursor..<(cursor + n)])
        cursor += n
        return slice
    }

    private func readU16(at i: Int) -> UInt16 { UInt16(buffer[i]) << 8 | UInt16(buffer[i + 1]) }
    private func readU32(at i: Int) -> UInt32 {
        UInt32(buffer[i]) << 24 | UInt32(buffer[i + 1]) << 16 | UInt32(buffer[i + 2]) << 8 | UInt32(buffer[i + 3])
    }

    private mutating func compact() {
        if cursor == buffer.count { buffer.removeAll(keepingCapacity: true); cursor = 0 }
        else if cursor > 1 << 16 { buffer.removeFirst(cursor); cursor = 0 }
    }
}

public enum RFBError: Error, Equatable, Sendable {
    case protocolVersion(String)
    case noSupportedSecurity([UInt8])
    case securityFailed(String)
    case unknownMessage(UInt8)
    case unsupportedEncoding(Int32)
    case malformed(String)
}

/// The client-side framebuffer: BGRX, 4 bytes per pixel, row-major.
public struct RFBFramebuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: max(0, width) * max(0, height) * 4)
    }

    public var bytesPerRow: Int { width * 4 }

    /// The 4 bytes (B, G, R, X) at a pixel.
    public func pixel(x: Int, y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(pixels[i..<(i + 4)])
    }

    private func check(x: Int, y: Int, width w: Int, height h: Int) throws {
        guard x >= 0, y >= 0, w >= 0, h >= 0, x + w <= width, y + h <= height else {
            throw RFBError.malformed("rect \(x),\(y) \(w)x\(h) outside \(width)x\(height)")
        }
    }

    mutating func applyRaw(x: Int, y: Int, width w: Int, height h: Int, bytes: [UInt8], offset: Int) throws {
        try check(x: x, y: y, width: w, height: h)
        let rowBytes = w * 4
        pixels.withUnsafeMutableBytes { dst in
            bytes.withUnsafeBytes { src in
                for row in 0..<h {
                    let d = ((y + row) * width + x) * 4
                    let s = offset + row * rowBytes
                    dst.baseAddress!.advanced(by: d).copyMemory(from: src.baseAddress!.advanced(by: s), byteCount: rowBytes)
                }
            }
        }
    }

    mutating func applyCopyRect(x: Int, y: Int, width w: Int, height h: Int, sourceX: Int, sourceY: Int) throws {
        try check(x: x, y: y, width: w, height: h)
        try check(x: sourceX, y: sourceY, width: w, height: h)
        let rowBytes = w * 4
        // Overlap-safe: walk rows away from the destination.
        let rows: [Int] = sourceY < y ? Array((0..<h).reversed()) : Array(0..<h)
        pixels.withUnsafeMutableBytes { buf in
            for row in rows {
                let s = ((sourceY + row) * width + sourceX) * 4
                let d = ((y + row) * width + x) * 4
                buf.baseAddress!.advanced(by: d).copyMemory(from: UnsafeRawPointer(buf.baseAddress!.advanced(by: s)), byteCount: rowBytes)
            }
        }
    }
}

/// Server→client encoders for deterministic fixtures (simulator scripted
/// desktop + unit tests). Never used against a live gateway.
public enum RFBServerFixture {
    public static let version = Data("RFB 003.008\n".utf8)

    public static func securityTypes(_ types: [UInt8]) -> Data { Data([UInt8(types.count)] + types) }

    public static func securityResultOK() -> Data { Data([0, 0, 0, 0]) }

    public static func serverInit(width: Int, height: Int, name: String) -> Data {
        var d = Data()
        d.appendU16(UInt16(width)); d.appendU16(UInt16(height))
        d.append(contentsOf: [32, 24, 0, 1]); d.appendU16(255); d.appendU16(255); d.appendU16(255)
        d.append(contentsOf: [16, 8, 0, 0, 0, 0])
        let n = Data(name.utf8)
        d.appendU32(UInt32(n.count)); d.append(n)
        return d
    }

    public enum Rect {
        case raw(x: Int, y: Int, width: Int, height: Int, bgrx: [UInt8])
        case copy(x: Int, y: Int, width: Int, height: Int, sourceX: Int, sourceY: Int)
        case desktopSize(width: Int, height: Int)
    }

    public static func framebufferUpdate(_ rects: [Rect]) -> Data {
        var d = Data([0, 0])
        d.appendU16(UInt16(rects.count))
        for r in rects {
            switch r {
            case let .raw(x, y, w, h, px):
                d.appendRectHeader(x, y, w, h, RFBClientSession.encodingRaw); d.append(contentsOf: px)
            case let .copy(x, y, w, h, sx, sy):
                d.appendRectHeader(x, y, w, h, RFBClientSession.encodingCopyRect); d.appendU16(UInt16(sx)); d.appendU16(UInt16(sy))
            case let .desktopSize(w, h):
                d.appendRectHeader(0, 0, w, h, RFBClientSession.encodingDesktopSize)
            }
        }
        return d
    }
}

/// X11 keysyms for the iOS keyboard bridge.
public enum RFBKeysym {
    public static let backspace: UInt32 = 0xff08
    public static let tab: UInt32 = 0xff09
    public static let returnKey: UInt32 = 0xff0d
    public static let escape: UInt32 = 0xff1b
    public static let left: UInt32 = 0xff51
    public static let up: UInt32 = 0xff52
    public static let right: UInt32 = 0xff53
    public static let down: UInt32 = 0xff54

    /// Latin-1 maps 1:1; any other Unicode scalar uses the 0x01000000 range.
    public static func forCharacter(_ c: Character) -> [UInt32] {
        if c == "\n" || c == "\r" || c == "\r\n" { return [returnKey] }
        if c == "\t" { return [tab] }
        return c.unicodeScalars.map { s in
            let v = s.value
            if (0x20...0x7e).contains(v) || (0xa0...0xff).contains(v) { return v }
            return 0x0100_0000 | v
        }
    }
}

extension Data {
    mutating func appendU16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func appendU32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
    }
    mutating func appendRectHeader(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ enc: Int32) {
        appendU16(UInt16(x)); appendU16(UInt16(y)); appendU16(UInt16(w)); appendU16(UInt16(h))
        appendU32(UInt32(bitPattern: enc))
    }
}
