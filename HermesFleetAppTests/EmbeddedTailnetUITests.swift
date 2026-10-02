import XCTest
import FleetCore
import FleetUI
import FleetNetworking

@MainActor
final class EmbeddedTailnetUITests: XCTestCase {
    func testGuidedPairingStartsNodeWaitsForBrowserAndResumesOnlyAfterTrust() async throws {
        let service = GuidedService()
        var completions = 0
        let model = GuidedPairingModel(service: service) { _ in completions += 1 }
        await model.begin(try PairingEnrollment.decode(Self.qr()))
        XCTAssertEqual(model.state, .waitingForLogin)
        XCTAssertEqual(model.enrollmentURL?.host, "login.tailscale.com")
        XCTAssertEqual(completions, 0)
        await service.ready()
        await model.refresh()
        XCTAssertEqual(model.state, .awaitingTrust)
        XCTAssertEqual(completions, 0)
        model.trustConfirmed = true
        await model.refresh()
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(completions, 1)
        await model.refresh()
        XCTAssertEqual(completions, 1)
    }

    func testGuidedPairingRejectsUnsafeBrowserURL() async throws {
        let model = GuidedPairingModel(service: GuidedService(browser: "https://evil.example/a/fixture")) { _ in XCTFail() }
        await model.begin(try PairingEnrollment.decode(Self.qr()))
        XCTAssertNil(model.enrollmentURL)
        XCTAssertEqual(model.state, .failed)
    }

    func testGuidedPairingDoesNotCompleteAfterCancelledCallback() async throws {
        let service = GuidedService()
        var continuation: CheckedContinuation<Void, Never>?
        let model = GuidedPairingModel(service: service) { _ in
            await withCheckedContinuation { continuation = $0 }
        }
        await model.begin(try PairingEnrollment.decode(Self.qr()))
        model.trustConfirmed = true
        await service.ready()
        let task = Task { await model.refresh() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
        task.cancel()
        continuation?.resume()
        await task.value
        XCTAssertNotEqual(model.state, .connected)
        XCTAssertNil(model.enrollmentURL)
    }

    func testReplacingDraftCancelsPendingPairingAndClearsSecret() async throws {
        let service = GuidedService()
        var completed = false
        let model = GuidedPairingModel(service: service) { _ in completed = true }
        let draft = GatewayFormDraftStore()
        draft.begin(pendingSheet: .add, initial: nil)
        try draft.applyPairing(Self.qr())
        draft.guidedPairing = model
        await model.begin(try XCTUnwrap(draft.pendingEnrollment))
        draft.clear()
        model.trustConfirmed = true
        await service.ready()
        await model.refresh()
        XCTAssertFalse(completed)
        XCTAssertNotEqual(model.state, .connected)
    }

    func testBrowserReturnResumesSuspendedNodeBeforeCheckingReadiness() async throws {
        let service = GuidedService()
        var completions = 0
        let model = GuidedPairingModel(service: service) { _ in completions += 1 }
        await model.begin(try PairingEnrollment.decode(Self.qr()))
        model.trustConfirmed = true
        try await service.suspend()
        await model.refresh()
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(completions, 1)
    }

    func testNativeRejectionIsActionableAndReadinessTimeoutIsNotCredentialExpiry() async throws {
        let service = GuidedService()
        let rejected = GuidedPairingModel(service: service) { _ in throw FleetPairingError.rejected }
        await rejected.begin(try PairingEnrollment.decode(Self.qr()))
        rejected.trustConfirmed = true
        await service.ready()
        await rejected.refresh()
        XCTAssertTrue(rejected.errorMessage?.contains("rejected") == true)
        var now = Date()
        let waiting = GuidedPairingModel(service: GuidedService(), now: { now }) { _ in XCTFail("Timed out wait must not log in") }
        await waiting.begin(try PairingEnrollment.decode(Self.qr()))
        now = now.addingTimeInterval(181)
        await waiting.refresh()
        XCTAssertEqual(waiting.state, .failed)
        XCTAssertTrue(waiting.errorMessage?.contains("timed out") == true)
        XCTAssertNoThrow(try PairingEnrollment.decode(Self.qr()), "Native QR has no invented expiry")
    }

    func testLateEnrollmentFailureCannotFailReplacement() async throws {
        for phase in DeferredFailureService.Phase.allCases {
            let service = DeferredFailureService(phase: phase)
            var completions = 0
            let model = GuidedPairingModel(service: service) { _ in completions += 1 }
            let enrollment = try PairingEnrollment.decode(Self.qr())
            let old = Task { await model.begin(enrollment) }
            await service.waitUntilBlocked()
            await model.begin(enrollment)
            XCTAssertEqual(model.state, .awaitingTrust, "Replacement must not inherit old busy ownership: \(phase)")
            await service.releaseFailure()
            await old.value
            XCTAssertEqual(model.state, .awaitingTrust, "Stale failure must not clear replacement: \(phase)")
            model.trustConfirmed = true
            await model.refresh()
            XCTAssertEqual(completions, 1, "Replacement remains usable: \(phase)")
        }
    }

    actor DeferredFailureService: EmbeddedTailnetManaging {
        enum Phase: CaseIterable { case start, resume, login }
        let phase: Phase
        var starts = 0
        var held = false
        var waiter: CheckedContinuation<Void, Never>?
        var failure: CheckedContinuation<Void, Error>?
        var current = EmbeddedTailnetSnapshot(state: .running)
        init(phase: Phase) { self.phase = phase }
        func hold(_ point: Phase) async throws {
            guard point == phase, !held else { return }
            held = true
            try await withCheckedThrowingContinuation { continuation in
                failure = continuation
                waiter?.resume(); waiter = nil
            }
        }
        func waitUntilBlocked() async {
            if failure != nil { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func releaseFailure() { failure?.resume(throwing: FleetPairingError.unavailable); failure = nil }
        func start() async throws {
            starts += 1
            current = .init(state: starts == 1 && phase == .login ? .needsLogin : .running)
            try await hold(.start)
        }
        func resume() async throws { try await hold(.resume) }
        func login() async throws { try await hold(.login) }
        func stop() async throws {}
        func logout() async throws {}
        func snapshot() async -> EmbeddedTailnetSnapshot { current }
    }

    actor GuidedService: EmbeddedTailnetManaging {
        var current = EmbeddedTailnetSnapshot(state: .stopped)
        let browser: String
        init(browser: String = "https://login.tailscale.com/a/fixture") { self.browser = browser }
        func start() async throws { current = .init(state: .needsLogin) }
        func login() async throws { current.enrollmentURL = URL(string: browser) }
        var suspended = false
        func suspend() async throws { suspended = true; current = .init(state: .stopped) }
        func resume() async throws {
            if suspended { suspended = false; current = .init(state: .running) }
        }
        func ready() { current = .init(state: .running) }
        func stop() async throws { current = .init(state: .stopped) }
        func logout() async throws { try await stop() }
        func snapshot() async -> EmbeddedTailnetSnapshot { current }
    }

    static func qr(auth: String = #"{"strategy":"usernamePassword","username":"fixture-user","password":"NOT-A-CREDENTIAL"}"#) -> String {
        """
        {"v":2,"kind":"hermes-fleet-ts","url":"https://gateway.example.ts.net","transport":"embeddedTailscale","auth":\(auth)}
        """
    }

    func testGatewayDraftPreservesTransportAndResetsForNewGateway() {
        let draft = GatewayFormDraftStore()
        let gateway = FleetGateway(id: GatewayID(rawValue: "fixture"), displayName: "Fixture", transport: .embeddedTailscale)
        draft.begin(pendingSheet: .edit(gateway.id), initial: gateway)
        XCTAssertEqual(draft.transport, .embeddedTailscale)
        draft.clear()
        XCTAssertEqual(draft.transport, .system)
    }

    actor Service: EmbeddedTailnetManaging {
        var state = EmbeddedTailnetState.stopped
        func start() async throws { state = .needsLogin }
        func login() async throws { state = .needsLogin }
        func stop() async throws { state = .stopped }
        func logout() async throws { state = .stopped }
        func snapshot() async -> EmbeddedTailnetSnapshot { .init(state: state) }
    }
    func testEnrollmentModelShowsActualStatusAndClearsOnLogout() async {
        let model = EmbeddedTailnetViewModel(service: Service())
        await model.start()
        XCTAssertEqual(model.status.state, .needsLogin)
        await model.logout()
        XCTAssertEqual(model.status.state, .stopped)
        XCTAssertNil(model.status.enrollmentURL)
        XCTAssertFalse(model.busy)
    }
}
