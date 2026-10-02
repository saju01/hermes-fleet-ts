import Foundation
import Observation
import FleetCore

@MainActor @Observable
public final class GuidedPairingModel {
    public enum State: String, Sendable {
        case idle = "Scan the private pairing code"
        case starting = "Starting Fleet's embedded Tailscale…"
        case waitingForLogin = "Sign in to Tailscale in your browser"
        case waitingForApproval = "Approve this Fleet device in Tailscale"
        case awaitingTrust = "Confirm the gateway address and TLS trust"
        case verifying = "Verifying secure gateway connection…"
        case connected = "Connected"
        case failed = "Connection could not be verified"
    }
    public private(set) var state: State = .idle
    public private(set) var enrollmentURL: URL?
    public private(set) var errorMessage: String?
    public var trustConfirmed = false
    private let service: any EmbeddedTailnetManaging
    private let complete: @MainActor (PairingEnrollment) async throws -> Void
    private let now: @MainActor () -> Date
    public init(service: any EmbeddedTailnetManaging, now: @escaping @MainActor () -> Date = Date.init, complete: @escaping @MainActor (PairingEnrollment) async throws -> Void) {
        self.now = now
        self.service = service
        self.complete = complete
    }
    private var deadline = Date.distantPast
    private var generation = UUID()
    private var verification: Task<Void, Error>?
    private var pending: PairingEnrollment?
    private var busy: UUID?
    private var loginRequested = false
    public func begin(_ enrollment: PairingEnrollment) async {
        cancel()
        guard !Task.isCancelled else { return }
        let generation = self.generation
        loginRequested = false
        errorMessage = nil
        deadline = now().addingTimeInterval(180)
        pending = enrollment
        trustConfirmed = false
        state = .starting
        do {
            try await service.start()
            guard generation == self.generation else { return }
            await refresh()
        } catch {
            guard generation == self.generation else { return }
            fail()
        }
    }
    public func refresh() async {
        guard let pending, busy == nil else { return }
        guard now() < deadline else { fail(.timedOut); return }
        guard !Task.isCancelled else { return }
        let generation = self.generation
        busy = generation
        defer { if busy == generation { busy = nil } }
        // Browser handoff may suspend/recreate the embedded listener. Await
        // its existing user-started intent before testing readiness; do not
        // race the composition root's foreground-resume task.
        do { try await service.resume() } catch {
            guard generation == self.generation else { return }
            fail(); return
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        var snapshot = await service.snapshot()
        guard generation == self.generation, !Task.isCancelled else { return }
        if snapshot.state == .needsLogin && !loginRequested {
            loginRequested = true
            do { try await service.login() } catch {
                guard generation == self.generation else { return }
                fail(); return
            }
            guard generation == self.generation, !Task.isCancelled else { return }
            snapshot = await service.snapshot()
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        guard now() < deadline else { fail(.timedOut); return }
        if let url = snapshot.enrollmentURL {
            guard url.scheme == "https", url.host == "login.tailscale.com", url.port == nil,
                  url.user == nil, url.password == nil, url.fragment == nil, url.path.hasPrefix("/a/") else { fail(); return }
        }
        enrollmentURL = snapshot.enrollmentURL
        switch snapshot.state {
        case .running:
            enrollmentURL = nil
            guard trustConfirmed else { state = .awaitingTrust; return }
            state = .verifying
            self.pending = nil
            do {
                let task = Task { try await complete(pending) }
                verification = task
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                verification = nil
                state = .connected
            } catch {
                guard generation == self.generation else { return }
                fail(error as? FleetPairingError ?? .unavailable)
            }
        case .needsLogin: state = .waitingForLogin
        case .needsApproval: state = .waitingForApproval
        case .starting: state = .starting
        case .stopped, .failed: fail()
        }
    }
    public func cancel() {
        generation = UUID()
        busy = nil
        verification?.cancel()
        verification = nil
        pending = nil
        enrollmentURL = nil
        state = .idle
        trustConfirmed = false
    }
    private func fail(_ reason: FleetPairingError = .unavailable) {
        pending = nil
        enrollmentURL = nil
        state = .failed
        verification = nil
        switch reason {
        case .cleanupRequired:
            errorMessage = "Pairing stopped, but cleanup could not finish. Some setup data may remain. Unlock the device and remove the incomplete gateway or review TLS trust settings before retrying."
        case .rejected:
            errorMessage = "Hermes rejected the QR credentials or the native session expired. Check the gateway’s supported authentication and privately scan updated credentials."
        case .timedOut:
            errorMessage = "Waiting for Tailscale or gateway confirmation timed out. Finish enrollment and scan again. This does not change the validity of your Hermes credential."
        default:
            errorMessage = "Connection could not be verified. Check Tailscale access, TLS trust and the gateway, then scan again. No direct-network or passwordless fallback was used."
        }
    }
}
