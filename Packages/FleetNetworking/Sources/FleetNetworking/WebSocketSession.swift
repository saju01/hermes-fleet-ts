import Foundation
import os

/// A message received from / sent to the gateway socket.
public enum WebSocketMessage: Sendable, Hashable, Equatable {
    case text(String)
    case data(Data)
}

/// T3 — thrown when the TLS trust handler REJECTED the peer because the
/// presented certificate was rejected by the pin policy. It may be a changed
/// key or an unapproved first-use key. Carries only public key material so the
/// UI can render the appropriate re-pair/confirmation flow.
public struct TLSPinRejectedError: Error, Sendable, Equatable {
    public let expected: String
    public let presented: String
    public let requiresFirstUseConfirmation: Bool
    public init(
        expected: String,
        presented: String,
        requiresFirstUseConfirmation: Bool = false
    ) {
        self.expected = expected
        self.presented = presented
        self.requiresFirstUseConfirmation = requiresFirstUseConfirmation
    }
}

/// The transport's seam over a WebSocket connection. The concrete
/// implementation wraps `URLSessionWebSocketTask`; tests inject fakes or point
/// the real one at an in-process fixture server.
public protocol WebSocketSession: Sendable {
    /// Establish the connection (resume the task).
    func open() async throws
    /// Receive the next message. Throws when the socket closes or errors;
    /// the resulting `closeCode` (if any) is available via `lastCloseCode`.
    func receive() async throws -> WebSocketMessage
    /// Send a text or data message.
    func send(_ message: WebSocketMessage) async throws
    /// Close the connection with a close code + optional reason.
    func close(code: Int, reason: String?) async
    /// The raw close code observed from the peer (nil until the socket closed).
    var lastCloseCode: Int? { get }
}

/// Factory producing sessions, so the transport can be built with the real
/// `URLSessionWebSocketTask` implementation or a test double.
public protocol WebSocketSessionFactory: Sendable {
    func makeSession(url: URL) -> any WebSocketSession
}

/// Concrete `URLSessionWebSocketTask`-backed session.
///
/// URLSession retains its delegate, so this session owns a dedicated
/// `URLSession` configured with a small delegate object (retained by us) that
/// forwards the server's close code through a closure. We also retain the
/// delegate, breaking the only would-be cycle (delegate → nothing).
///
/// T3: an optional `PinningTrustHandler` decides server-trust challenges
/// (TOFU SPKI pinning). When the handler REJECTS (pin mismatch), the
/// challenge is cancelled AND a `TLSPinRejectedError` is recorded so the
/// subsequent receive/open failure surfaces as the typed pin-mismatch error
/// rather than an opaque `NSURLErrorCancelled`.
public final class URLSessionWebSocketSession: WebSocketSession, @unchecked Sendable {
    private final class CloseDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        var onClose: (@Sendable (Int, Data?) -> Void)?
        let trustHandler: PinningTrustHandler?
        let rejectRedirects: Bool
        private let failureLock = OSAllocatedUnfairLock<TLSPinRejectedError?>(initialState: nil)

        init(trustHandler: PinningTrustHandler?, rejectRedirects: Bool) {
            self.trustHandler = trustHandler
            self.rejectRedirects = rejectRedirects
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(rejectRedirects ? nil : request)
        }

        /// The typed pin-mismatch failure recorded by the challenge path
        /// (nil unless the handler rejected a server-trust challenge).
        var pendingPinRejection: TLSPinRejectedError? {
            failureLock.withLock { $0 }
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            onClose?(closeCode.rawValue, reason)
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            // Session-level callback: this is the one invoked for the
            // initial TLS server-trust handshake on WebSocket tasks.
            handleChallenge(challenge, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handleChallenge(challenge, completionHandler: completionHandler)
        }

        private func handleChallenge(
            _ challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let trustHandler else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            trustHandler.evaluate(challenge) { [weak self] disposition, credential in
                if disposition == .cancelAuthenticationChallenge {
                    let verdict = self?.trustHandler?.lastVerdict
                    self?.failureLock.withLock { box in
                        guard box == nil else { return }
                        guard let verdict else { return }
                        switch verdict {
                        case .pinMismatch(let expected, let presented):
                            box = TLSPinRejectedError(
                                expected: expected.base64String,
                                presented: presented.base64String)
                        case .firstUseRequiresConfirmation(let presented):
                            box = TLSPinRejectedError(
                                expected: "first-use-approval-required",
                                presented: presented.base64String,
                                requiresFirstUseConfirmation: true)
                        default:
                            break
                        }
                    }
                }
                completionHandler(disposition, credential)
            }
        }
    }

    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask
    private let delegate: CloseDelegate
    private let lock = OSAllocatedUnfairLock<Int?>(initialState: nil)

    private var lifetime: GatewaySessionLifetime?
    private var lifetimeID: UUID?

    public init(url: URL, configuration: URLSessionConfiguration = .ephemeral, trustHandler: PinningTrustHandler? = nil, rejectRedirects: Bool = false) {
        let delegate = CloseDelegate(trustHandler: trustHandler, rejectRedirects: rejectRedirects)
        self.delegate = delegate
        self.urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.task = urlSession.webSocketTask(with: url)
        delegate.onClose = { [weak self] code, _ in
            self?.lock.withLock { $0 = code }
        }
    }

    public var lastCloseCode: Int? {
        lock.withLock { $0 }
    }

    // Called once, before publishing/opening the socket.
    func bindLifetime(_ lifetime: GatewaySessionLifetime) throws {
        lifetimeID = try lifetime.register(urlSession)
        self.lifetime = lifetime
    }

    deinit {
        urlSession.invalidateAndCancel()
        if let lifetimeID { lifetime?.remove(lifetimeID) }
    }

    public func open() async throws {
        task.resume()
    }

    public func receive() async throws -> WebSocketMessage {
        do {
            let message = try await task.receive()
            switch message {
            case .string(let s): return .text(s)
            case .data(let d): return .data(d)
            @unknown default: return .data(Data())
            }
        } catch {
            // A pin rejection recorded by the challenge path explains this
            // failure — surface the TYPED error (T3).
            if let rejection = delegate.pendingPinRejection {
                throw rejection
            }
            // On close URLSession reports a generic URLError; the close code
            // is captured by the delegate. Re-throw so the transport can
            // classify via lastCloseCode.
            throw error
        }
    }

    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let s): try await task.send(.string(s))
        case .data(let d): try await task.send(.data(d))
        }
    }

    public func close(code: Int, reason: String?) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason?.data(using: .utf8))
        urlSession.invalidateAndCancel()
        if let lifetimeID { lifetime?.remove(lifetimeID) }
        lock.withLock { $0 = code }
    }
}

/// Factory producing `URLSessionWebSocketTask` sessions. The default creates
/// the session from an ephemeral URLSession with a delegate, so close codes
/// are observable; callers may supply their own `URLSessionConfiguration`.
/// T3: pass a `trustHandler` to enforce TOFU SPKI pinning on wss://
/// connections (cleartext ws:// never raises server-trust challenges).
public struct URLSessionWebSocketSessionFactory: WebSocketSessionFactory {
    public let configuration: URLSessionConfiguration
    public let trustHandler: PinningTrustHandler?

    public init(configuration: URLSessionConfiguration = .ephemeral, trustHandler: PinningTrustHandler? = nil) {
        self.configuration = configuration
        self.trustHandler = trustHandler
    }

    public func makeSession(url: URL) -> any WebSocketSession {
        URLSessionWebSocketSession(url: url, configuration: configuration, trustHandler: trustHandler)
    }
}
