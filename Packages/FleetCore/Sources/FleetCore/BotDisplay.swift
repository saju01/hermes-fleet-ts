import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Hermes Bot Desktop domain + seams (Simple mode's live browser card).
///
/// Wire ground truth (hermes-agent `tui_gateway/contracts/display.py`,
/// `tui_gateway/methods_display.py`, `hermes_cli/web_routers/display.py`):
/// - `display.status {profile?}` → runtime + lease snapshot.
/// - `display.thumbnail {profile?}` → `{data_url|null, suppressed?}`; the
///   frame is withheld while a HUMAN holds the lease.
/// - `display.observe {profile?, viewer_id?}` → `{ticket, path, viewer_id,
///   ...status}`; the ticket is single-use with a 30 s life and the viewer id
///   is minted PER CONNECTION (acquire/release must ride the same socket).
/// - `display.lease.acquire {profile?, viewer_id}` / `display.lease.release
///   {profile?, viewer_id?}` → `{lease}` (Take control / Hand back).
/// - live view: raw RFB over a binary WebSocket at
///   `<path>?display_ticket=<ticket>`; close codes below.
/// Bot Desktop is Linux-only (`status.supported == false` elsewhere).

public enum DisplayLeaseHolder: String, Sendable, Hashable {
    case agent, human
}

public struct DisplayLease: Sendable, Hashable {
    public let holder: DisplayLeaseHolder
    /// Short hash of the holder's viewer id (the raw id never leaves the gateway).
    public let viewerHash: String?
    public let epoch: Int

    public init(holder: DisplayLeaseHolder, viewerHash: String? = nil, epoch: Int = 0) {
        self.holder = holder
        self.viewerHash = viewerHash
        self.epoch = epoch
    }

    /// Whether THIS viewer holds control (`viewer_hash` = sha256(id)[:12]).
    public func isHeld(by viewerID: String?) -> Bool {
        guard holder == .human, let viewerID, let viewerHash else { return false }
        return BotDisplayViewerHash.hash(viewerID) == viewerHash
    }
}

public enum BotDisplayViewerHash {
    public static func hash(_ viewerID: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(viewerID.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
        #else
        return ""
        #endif
    }
}

public struct DisplayStatusSnapshot: Sendable, Hashable {
    public let supported: Bool
    public let installed: Bool
    public let running: Bool
    public let geometry: String
    public let browser: String?
    public let blocker: String?
    public let lease: DisplayLease

    public init(supported: Bool, installed: Bool, running: Bool, geometry: String = "",
                browser: String? = nil, blocker: String? = nil,
                lease: DisplayLease = DisplayLease(holder: .agent)) {
        self.supported = supported
        self.installed = installed
        self.running = running
        self.geometry = geometry
        self.browser = browser
        self.blocker = blocker
        self.lease = lease
    }
}

public struct DisplayThumbnail: Sendable, Hashable {
    /// JPEG bytes decoded from the `data_url` (nil while stopped/suppressed).
    public let imageData: Data?
    /// Why the frame is withheld (a human holds the lease), else nil.
    public let suppressed: String?

    public init(imageData: Data?, suppressed: String?) {
        self.imageData = imageData
        self.suppressed = suppressed
    }

    /// Decode a `data:image/...;base64,` URL (nil for anything else).
    public static func decodeDataURL(_ string: String?) -> Data? {
        guard let string, string.hasPrefix("data:"),
              let comma = string.firstIndex(of: ","),
              string[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(string[string.index(after: comma)...]))
    }
}

public struct DisplayObservation: Sendable, Hashable {
    public let ticket: String
    public let path: String
    public let viewerID: String
    public let status: DisplayStatusSnapshot

    public init(ticket: String, path: String, viewerID: String, status: DisplayStatusSnapshot) {
        self.ticket = ticket
        self.path = path
        self.viewerID = viewerID
        self.status = status
    }
}

/// Close codes of `/api/display/ws` (hermes_cli/web_routers/display.py).
public enum DisplayCloseCode {
    public static let controlTaken = 4000
    public static let desktopGone = 4001
    public static let badTicket = 4401
    public static let notAllowed = 4403
}

public enum BotDisplayError: Error, Sendable, Equatable {
    case notConnected
    case unavailable(String)
    case rpcFailed(String)
    /// The RFB socket closed; `code` is the WebSocket close code when known.
    case streamClosed(code: Int?)
}

/// Binary RFB byte pipe over the display WebSocket.
public protocol DisplayByteStream: Sendable {
    func send(_ data: Data) async throws
    /// Next chunk from the server. Throws `BotDisplayError.streamClosed`.
    func receive() async throws -> Data
    func close() async
}

/// The Bot Desktop seam (FleetUI never sees the transport).
public protocol BotDisplayProviding: Sendable {
    func status(profile: String?) async throws -> DisplayStatusSnapshot
    func thumbnail(profile: String?) async throws -> DisplayThumbnail
    func observe(profile: String?, viewerID: String?) async throws -> DisplayObservation
    func acquireLease(profile: String?, viewerID: String, reason: String?) async throws -> DisplayLease
    func releaseLease(profile: String?, viewerID: String) async throws -> DisplayLease
    func openStream(_ observation: DisplayObservation) async throws -> any DisplayByteStream
}

/// Sessions whose transport also carries the Bot Desktop surface (same
/// one-cast discipline as `ApprovalsCapable`). The display seam MUST share
/// the session's connection: `display.observe` mints viewer ids per
/// connection and `display.lease.*` refuses foreign ids.
public protocol BotDisplayCapable: ConversationSessionProviding {
    var display: any BotDisplayProviding { get }
}

// MARK: - Viewer state machine

public enum DisplayEndReason: Equatable, Sendable {
    case closedByUser
    case desktopGone
    case notAllowed
    case ticketRejected
    case failed(String)
}

public enum DisplayViewerPhase: Equatable, Sendable {
    case idle
    case observing
    case connecting
    case watching
    case acquiring
    case controlling
    case releasing
    case ended(DisplayEndReason)

    public var isLive: Bool {
        switch self {
        case .watching, .acquiring, .controlling, .releasing: true
        default: false
        }
    }
}

/// Side effects the driver performs for a transition.
public enum DisplayViewerEffect: Equatable, Sendable {
    case observe(viewerID: String?)
    case openStream
    case acquire(viewerID: String)
    case release(viewerID: String)
    case closeStream
}

/// Pure Watch / Take control / Hand back state machine. The driver (view
/// model) performs the returned effects and reports results back. Input may
/// reach the desktop ONLY in `.controlling` — the gateway also enforces this
/// (rfb_filter.py drops input from non-holders), this is the client mirror.
public struct DisplayViewerMachine: Equatable, Sendable {
    public private(set) var phase: DisplayViewerPhase = .idle
    public private(set) var viewerID: String?
    /// Re-observe budget for 4401 (expired/used ticket) — one silent retry.
    public private(set) var ticketRetriesLeft = 1
    /// A human asked for control before the stream was up.
    private var wantsControl = false

    public init() {}

    public var canSendInput: Bool { phase == .controlling }

    public mutating func start(takeControl: Bool = false) -> [DisplayViewerEffect] {
        switch phase {
        case .idle, .ended:
            wantsControl = takeControl
            ticketRetriesLeft = 1
            phase = .observing
            return [.observe(viewerID: viewerID)]
        default:
            return []
        }
    }

    public mutating func observed(viewerID: String) -> [DisplayViewerEffect] {
        guard phase == .observing else { return [] }
        self.viewerID = viewerID
        phase = .connecting
        return [.openStream]
    }

    /// The RFB handshake completed (ServerInit parsed).
    public mutating func streamReady() -> [DisplayViewerEffect] {
        guard phase == .connecting, let viewerID else { return [] }
        if wantsControl {
            wantsControl = false
            phase = .acquiring
            return [.acquire(viewerID: viewerID)]
        }
        phase = .watching
        return []
    }

    public mutating func requestControl() -> [DisplayViewerEffect] {
        switch phase {
        case .watching:
            guard let viewerID else { return [] }
            phase = .acquiring
            return [.acquire(viewerID: viewerID)]
        case .observing, .connecting:
            wantsControl = true
            return []
        default:
            return []
        }
    }

    public mutating func leaseResult(_ lease: DisplayLease) -> [DisplayViewerEffect] {
        switch phase {
        case .acquiring:
            phase = lease.isHeld(by: viewerID) ? .controlling : .watching
        case .releasing:
            phase = lease.isHeld(by: viewerID) ? .controlling : .watching
        case .controlling where !lease.isHeld(by: viewerID):
            phase = .watching
        default:
            break
        }
        return []
    }

    public mutating func leaseFailed() -> [DisplayViewerEffect] {
        if phase == .acquiring { phase = .watching }
        if phase == .releasing { phase = .controlling }
        return []
    }

    public mutating func requestHandBack() -> [DisplayViewerEffect] {
        guard phase == .controlling, let viewerID else { return [] }
        phase = .releasing
        return [.release(viewerID: viewerID)]
    }

    /// The display socket closed with `code` (nil = transport failure).
    public mutating func streamClosed(code: Int?) -> [DisplayViewerEffect] {
        if case .ended = phase { return [] }
        if phase == .idle { return [] }
        switch code {
        case DisplayCloseCode.controlTaken:
            // Another human took over: drop back to watching on a fresh ticket.
            wantsControl = false
            phase = .observing
            return [.observe(viewerID: viewerID)]
        case DisplayCloseCode.desktopGone:
            phase = .ended(.desktopGone)
            return []
        case DisplayCloseCode.notAllowed:
            phase = .ended(.notAllowed)
            return []
        case DisplayCloseCode.badTicket:
            if ticketRetriesLeft > 0 {
                ticketRetriesLeft -= 1
                phase = .observing
                return [.observe(viewerID: viewerID)]
            }
            phase = .ended(.ticketRejected)
            return []
        default:
            phase = .ended(.failed(code.map { "closed (\($0))" } ?? "connection lost"))
            return []
        }
    }

    public mutating func failed(_ message: String) -> [DisplayViewerEffect] {
        if case .ended = phase { return [] }
        phase = .ended(.failed(message))
        return [.closeStream]
    }

    /// The user closed the viewer. A held lease is handed back first so the
    /// agent never stays locked out.
    public mutating func close() -> [DisplayViewerEffect] {
        var effects: [DisplayViewerEffect] = []
        if phase == .controlling || phase == .acquiring || phase == .releasing, let viewerID {
            effects.append(.release(viewerID: viewerID))
        }
        if case .ended = phase {} else if phase != .idle { effects.append(.closeStream) }
        phase = .ended(.closedByUser)
        wantsControl = false
        return effects
    }
}
