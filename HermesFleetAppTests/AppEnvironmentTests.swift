import XCTest
import os
import Network
import CryptoKit
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// U1 runtime tests: the `AppEnvironment` observable application runtime
/// composes the registry / roster / cache / connection seams and OWNS the
/// connection lifecycle (connect / disconnect / reconnect states observable).
///
/// All seams are scripted (in-memory stores + scripted connections) — no
/// network, no Keychain writes. This is the app-target test bundle, so it may
/// import FleetNetworking (the app composition root is the ONLY allowed
/// consumer); FleetUI itself stays import-free of the transport module.
@MainActor
final class AppEnvironmentTests: XCTestCase {

    func testPrivateQRPopulatesNativeAuthenticationThenLogsInOnceAfterEmbeddedReadiness() async throws {
        let server = try PairingWireFixture()
        try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(server.listeningPort)")!
        let credentials = KeychainCredentialStore()
        let records = PairingFailingRecordStore()
        let qr = EmbeddedTailnetUITests.qr().replacingOccurrences(of: "gateway.example.ts.net", with: "fixture-" + UUID().uuidString.lowercased() + ".example.ts.net")
        let draft = GatewayFormDraftStore()
        draft.begin(pendingSheet: .add, initial: nil)
        try draft.applyPairing(qr)
        XCTAssertEqual(draft.strategy, .usernamePassword)
        XCTAssertEqual(draft.usernameText, "fixture-user")
        XCTAssertEqual(draft.passwordText, "NOT-A-CREDENTIAL")
        let enrollment = try XCTUnwrap(draft.takeEnrollment())
        let id = GatewayID(endpoint: enrollment.origin)
        addTeardownBlock { try await credentials.deleteCredential(for: id) }
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) }, recordStore: records)
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let sessionStore = GatewaySessionStore()
        server.primeSession()
        _ = try await sessionStore.lease(gatewayID: id) { SessionCookie(name: "hermes_session_at", value: "fixture-native-session") }
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                SingleGatewayConnection(gatewayID: gateway.id, displayName: gateway.displayName, endpoint: gateway.endpoint,
                    transport: GatewayWebSocketTransport(baseURL: base,
                        authentication: GatewayAuthenticator(gatewayID: gateway.id, strategy: gateway.authConfiguration.strategy,
                            credentialStore: credentials, baseURL: base, urlSession: URLSession(configuration: .ephemeral), sessionStore: sessionStore), configuration: .standard))
            }, health: TestHealthAccumulator(), gatewaySessionInvalidator: { id in await sessionStore.invalidate(gatewayID: id) }, pairingConnectionFactory: { gateway, lease in
                SingleGatewayConnection(gatewayID: gateway.id, displayName: gateway.displayName, endpoint: gateway.endpoint,
                    transport: GatewayWebSocketTransport(baseURL: base,
                        authentication: GatewayAuthenticator(gatewayID: gateway.id, strategy: gateway.authConfiguration.strategy,
                            credentialStore: PairingCredentialStore(lease: lease, persistentStore: credentials), baseURL: base,
                            urlSession: URLSession(configuration: .ephemeral), sessionStore: PairingSessionStore(credentialLease: lease)), configuration: .standard))
            }, pairingCredentialStore: credentials)
        let service = EmbeddedTailnetUITests.GuidedService()
        let guide = GuidedPairingModel(service: service) { enrollment in
            _ = try await environment.completePairing(enrollment, confirmsTLSFirstUse: true)
        }
        await guide.begin(enrollment)
        guide.trustConfirmed = true
        XCTAssertTrue(server.paths.isEmpty, "No HTTP/password before embedded readiness")
        let before = try await credentials.loadCredential(for: id)
        XCTAssertNil(before)
        await service.ready()
        await guide.refresh()
        XCTAssertEqual(guide.state, .connected)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        let sharedAfterPairing = try await sessionStore.lease(gatewayID: id) {
            SessionCookie(name: "hermes_session_at", value: "fresh-callback-fixture")
        }
        XCTAssertEqual(sharedAfterPairing.value, "fresh-callback-fixture", "Downstream roster connections must not inherit a stale shared cookie")
        XCTAssertEqual(server.paths, ["/api/auth/providers", "/auth/password-login", "/api/auth/ws-ticket", "/api/ws"])
        let stored = try await KeychainCredentialStore().loadCredential(for: id)
        XCTAssertEqual(stored?.rawValue, "NOT-A-CREDENTIAL")
        XCTAssertEqual(stored?.username, "fixture-user")
        await environment.reconnect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        XCTAssertEqual(server.paths.filter { $0 == "/auth/password-login" }.count, 1, "Native session lease reused; no second password prompt/login")
        for persistenceFails in [true, false] {
            await records.setFailWrites(persistenceFails)
            do {
                try await environment.saveCredential(GatewayCredential(rawValue: "WRONG-FIXTURE", username: "fixture-user"), for: id)
                XCTAssertFalse(persistenceFails, "Injected metadata write must fail after Keychain upsert")
            } catch {
                if !persistenceFails { throw error }
                guard case GatewayRegistryError.recordStoreFailed = error else {
                    XCTFail("Expected metadata persistence failure, not another error"); throw error
                }
            }
            await environment.reconnect(to: id)
            XCTAssertNotEqual(environment.connectionStates[id], .connected, "Credential replacement must retire old cookies even when metadata persistence fails")
            await records.setFailWrites(false)
            try await environment.saveCredential(GatewayCredential(rawValue: "NOT-A-CREDENTIAL", username: "fixture-user"), for: id)
            await environment.reconnect(to: id)
            XCTAssertEqual(environment.connectionStates[id], .connected)
        }
        server.revoke()
        await environment.reconnect(to: id)
        XCTAssertNotEqual(environment.connectionStates[id], .connected)
        await environment.disconnect(from: id)
    }

    func testNativePairingConnectionFailureRollsBackSavedCredential() async throws {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) })
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .failure(.authenticationRequired)) }, health: TestHealthAccumulator(),
            pairingConnectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .failure(.authenticationRequired)) }, pairingCredentialStore: credentials)
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        do { _ = try await environment.completePairing(enrollment, confirmsTLSFirstUse: true); XCTFail() } catch {}
        let gateways = await registry.allGateways()
        XCTAssertTrue(gateways.isEmpty)
        let stored = try await credentials.loadCredential(for: GatewayID(endpoint: enrollment.origin))
        XCTAssertNil(stored)
    }

    func testNativeSessionTokenWorksAndRejectedCredentialsNeverReportConnected() async throws {
        for auth in [#"{"strategy":"sessionToken","token":"fixture-native-token"}"#, #"{"strategy":"sessionToken","token":"invalid-native-token"}"#, #"{"strategy":"usernamePassword","username":"fixture-user","password":"wrong-password"}"#] {
            let server = try PairingWireFixture()
            try await server.start()
            defer { server.stop() }
            let base = URL(string: "http://127.0.0.1:\(server.listeningPort)")!
            let credentials = InMemoryCredentialStore()
            let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) })
            let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
            let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(),
                connectionFactory: { gateway, _ in
                    SingleGatewayConnection(gatewayID: gateway.id, displayName: gateway.displayName, endpoint: gateway.endpoint,
                        transport: GatewayWebSocketTransport(baseURL: base, authentication: GatewayAuthenticator(gatewayID: gateway.id,
                            strategy: gateway.authConfiguration.strategy, credentialStore: credentials, baseURL: base, urlSession: URLSession(configuration: .ephemeral)), configuration: .standard))
                }, health: TestHealthAccumulator(), pairingConnectionFactory: { gateway, lease in
                    SingleGatewayConnection(gatewayID: gateway.id, displayName: gateway.displayName, endpoint: gateway.endpoint,
                        transport: GatewayWebSocketTransport(baseURL: base, authentication: GatewayAuthenticator(gatewayID: gateway.id,
                            strategy: gateway.authConfiguration.strategy, credentialStore: PairingCredentialStore(lease: lease, persistentStore: credentials),
                            baseURL: base, urlSession: URLSession(configuration: .ephemeral)), configuration: .standard))
                }, pairingCredentialStore: credentials)
            let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr(auth: auth))
            if auth.contains("fixture-native-token") {
                let id = try await environment.completePairing(enrollment, confirmsTLSFirstUse: true)
                XCTAssertEqual(environment.connectionStates[id], .connected)
                XCTAssertEqual(server.paths, ["/api/auth/ws-ticket", "/api/ws"])
                await environment.disconnect(from: id)
            } else {
                do { _ = try await environment.completePairing(enrollment, confirmsTLSFirstUse: true); XCTFail("Invalid native credential accepted") }
                catch { XCTAssertEqual(error as? FleetPairingError, .rejected) }
                let stored = try await credentials.loadCredential(for: GatewayID(endpoint: enrollment.origin))
                XCTAssertNil(stored)
                XCTAssertFalse(server.paths.contains("/api/ws"))
            }
        }
    }

    func testPendingPairingIsNotPersistedOrRestoredBeforeVerification() async throws {
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let id = GatewayID(endpoint: enrollment.origin)
        let credentials = InMemoryCredentialStore()
        let cache = try SwiftDataCacheStore.makeInMemory()
        let gate = PairingGateConnection(gatewayID: id)
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { _, _ in gate }, recordStore: cache)
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: cache, sessionList: TestSessionList(), connectionFactory: { _, _ in gate }, health: TestHealthAccumulator(), pairingConnectionFactory: { _, _ in gate }, pairingCredentialStore: credentials)
        let task = Task { try await environment.completePairing(enrollment, confirmsTLSFirstUse: true) }
        await gate.waitUntilConnecting()
        let stored = try await credentials.loadCredential(for: id)
        let records = try await cache.loadGatewayRecords()
        XCTAssertNil(stored, "Pending credential must never reach durable store")
        XCTAssertTrue(records.isEmpty, "No ordinary durable gateway before gateway.ready")
        XCTAssertFalse(environment.isConnectionIntended(id), "Unverified pairing must not autoconnect")
        let restarted = GatewayRegistryService(credentials: credentials, connectionFactory: { _, _ in gate }, recordStore: cache)
        let restored = try await restarted.restorePersistedGateways()
        XCTAssertTrue(restored.isEmpty, "A restart at this checkpoint must restore nothing")
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled pairing succeeded") } catch {}
    }

    func testCancellationRevokesCredentialAndClosesOwnedSocketBeforeLateCallback() async throws {
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let id = GatewayID(endpoint: enrollment.origin)
        let credentials = InMemoryCredentialStore()
        let gate = PairingGateConnection(gatewayID: id)
        let leaseBox = OSAllocatedUnfairLock<PairingCredentialLease?>(initialState: nil)
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { _, _ in gate })
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(),
            connectionFactory: { _, _ in gate }, health: TestHealthAccumulator(), pairingConnectionFactory: { _, lease in
                leaseBox.withLock { $0 = lease }; return gate
            }, pairingCredentialStore: credentials)
        let task = Task { try await environment.completePairing(enrollment, confirmsTLSFirstUse: true) }
        await gate.waitUntilConnecting()
        let lease = try XCTUnwrap(leaseBox.withLock { $0 })
        task.cancel()
        for _ in 0..<100 {
            if await gate.disconnects > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let disconnected = await gate.disconnects
        XCTAssertGreaterThan(disconnected, 0, "Cancel must close the owned socket without waiting for connect to return")
        let pending = try await lease.load(for: id, persistentStore: credentials)
        XCTAssertNil(pending, "Cancel must revoke the transient secret before the late callback")
        XCTAssertNil(environment.connectionStates[id])
        await gate.release()
        do { _ = try await task.value; XCTFail("Late callback must not commit") } catch {}
        XCTAssertNil(environment.connectionStates[id])
        XCTAssertFalse(environment.isConnectionIntended(id))
        let saved = try await credentials.loadCredential(for: id)
        XCTAssertNil(saved)
    }

    func testPairingRejectsExistingGatewayWithoutTouchingItsCredential() async throws {
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let id = GatewayID(endpoint: enrollment.origin)
        let credentials = InMemoryCredentialStore()
        let cache = try SwiftDataCacheStore.makeInMemory()
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) }, recordStore: cache)
        _ = try await registry.addGateway(.init(displayName: "Existing", endpoint: enrollment.origin, authConfiguration: .init(strategy: .usernamePassword), transport: .embeddedTailscale))
        let oldCredential = GatewayCredential(rawValue: "EXISTING-FIXTURE-ONLY", username: "existing")
        try await registry.saveCredential(oldCredential, for: id)
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let factoryCalls = OSAllocatedUnfairLock(initialState: 0)
        let environment = AppEnvironment(registry: registry, roster: roster, cache: cache, sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) }, health: TestHealthAccumulator(),
            pairingConnectionFactory: { gateway, _ in factoryCalls.withLock { $0 += 1 }; return TestConnection(gatewayID: gateway.id, result: .success(())) }, pairingCredentialStore: credentials)
        do { _ = try await environment.completePairing(enrollment, confirmsTLSFirstUse: true); XCTFail("Must reject duplicate") }
        catch GatewayRegistryError.duplicate(let duplicateID) { XCTAssertEqual(duplicateID, id) }
        let saved = try await credentials.loadCredential(for: id)
        XCTAssertEqual(saved, oldCredential)
        let existing = await registry.gateway(for: id)
        XCTAssertEqual(existing?.displayName, "Existing")
        XCTAssertEqual(factoryCalls.withLock { $0 }, 0)
    }

    func testPairingCredentialLeasePromotesToKeychainViewAndRevokesFallback() async throws {
        let id = GatewayID(rawValue: "fixture")
        let credentials = InMemoryCredentialStore()
        let transient = GatewayCredential(rawValue: "TRANSIENT-FIXTURE")
        let durable = GatewayCredential(rawValue: "DURABLE-FIXTURE")
        let lease = PairingCredentialLease(gatewayID: id, credential: transient)
        let view = PairingCredentialStore(lease: lease, persistentStore: credentials)
        try await credentials.saveCredential(durable, for: id)
        let pending = try await view.loadCredential(for: id)
        XCTAssertEqual(pending, transient)
        let foreign = try await view.loadCredential(for: GatewayID(rawValue: "other"))
        XCTAssertNil(foreign)
        try await lease.commit()
        let committed = try await view.loadCredential(for: id)
        XCTAssertEqual(committed, durable, "Committed connection must stop retaining/using its transient secret")
        await lease.revoke()
        let cancelled = try await view.loadCredential(for: id)
        XCTAssertNil(cancelled, "Revocation also closes the durable fallback")
        do { try await lease.commit(); XCTFail("Cannot revive revoked lease") } catch {}
        do { try await view.saveCredential(transient, for: id); XCTFail("Read-only view") } catch {}
        do { try await view.deleteCredential(for: id); XCTFail("Read-only view") } catch {}
        let retained = try await credentials.loadCredential(for: id)
        XCTAssertEqual(retained, durable)
    }

    func testBackgroundTeardownCancelsPendingPairingBeforePublication() async throws {
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let id = GatewayID(endpoint: enrollment.origin)
        let credentials = InMemoryCredentialStore()
        let gate = PairingGateConnection(gatewayID: id)
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { _, _ in gate })
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(), connectionFactory: { _, _ in gate }, health: TestHealthAccumulator(), pairingConnectionFactory: { _, _ in gate }, pairingCredentialStore: credentials)
        let task = Task { try await environment.completePairing(enrollment, confirmsTLSFirstUse: true) }
        await gate.waitUntilConnecting()
        await environment.disconnectAll()
        let disconnects = await gate.disconnects
        XCTAssertGreaterThan(disconnects, 0)
        await gate.release()
        do { _ = try await task.value; XCTFail("Backgrounded pairing must not publish") } catch {}
        XCTAssertNil(environment.connectionStates[id])
        XCTAssertFalse(environment.isConnectionIntended(id))
        let saved = try await credentials.loadCredential(for: id)
        XCTAssertNil(saved)
    }

    func testOrphanedCredentialIsNotOverwrittenByPairing() async throws {
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let id = GatewayID(endpoint: enrollment.origin)
        let credentials = InMemoryCredentialStore()
        let old = GatewayCredential(rawValue: "ORPHAN-FIXTURE-ONLY")
        try await credentials.saveCredential(old, for: id)
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) })
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(), connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) }, health: TestHealthAccumulator(), pairingConnectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) }, pairingCredentialStore: credentials)
        do { _ = try await environment.completePairing(enrollment, confirmsTLSFirstUse: true); XCTFail("Must preserve orphaned material") } catch {}
        let saved = try await credentials.loadCredential(for: id)
        XCTAssertEqual(saved, old)
    }

    func testFailedPairingPreservesPreexistingPinWithoutBlockingRetry() async throws {
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let id = GatewayID(endpoint: enrollment.origin)
        let credentials = PairingSaveFailureStore()
        let pins = PairingTestPinStore()
        let originalPin = SPKIFingerprint(rawBytes: Array(repeating: 7, count: 32))
        try await pins.savePin(originalPin, for: id)
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) }, pinStore: pins)
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), tlsPinStore: pins, sessionList: TestSessionList(), connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .success(())) }, health: TestHealthAccumulator(), pairingConnectionFactory: { gateway, _ in calls.withLock { $0 += 1 }; return TestConnection(gatewayID: gateway.id, result: .success(())) }, pairingCredentialStore: credentials)
        do { _ = try await environment.completePairing(enrollment, confirmsTLSFirstUse: true); XCTFail("Injected save failure") } catch {}
        XCTAssertEqual(calls.withLock { $0 }, 1, "A TLS pin left by an interrupted first pairing must not permanently block a retry")
        let pin = try await pins.loadPin(for: id)
        XCTAssertEqual(pin, originalPin, "Rollback must not delete previously trusted material")
        let row = await registry.gateway(for: id)
        XCTAssertNil(row)
    }

    func testCancelledPairingAllowsQueuedSameIDReplacement() async throws {
        try await exerciseQueuedReplacement(background: false)
    }
    func testBackgroundAlsoCancelsQueuedReplacement() async throws {
        try await exerciseQueuedReplacement(background: true)
    }
    private func exerciseQueuedReplacement(background: Bool) async throws {
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let id = GatewayID(endpoint: enrollment.origin)
        let credentials = InMemoryCredentialStore()
        let gate = PairingGateConnection(gatewayID: id)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { _, _ in gate })
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(), connectionFactory: { _, _ in gate }, health: TestHealthAccumulator(), pairingConnectionFactory: { gateway, _ in
            let count = calls.withLock { value in value += 1; return value }
            if count == 1 { return gate }
            return TestConnection(gatewayID: gateway.id, result: .success(()))
        }, pairingCredentialStore: credentials)
        let first = Task { try await environment.completePairing(enrollment, confirmsTLSFirstUse: true) }
        await gate.waitUntilConnecting()
        var entered = false
        let second = Task { entered = true; return try await environment.completePairing(enrollment, confirmsTLSFirstUse: true) }
        while !entered { await Task.yield() }
        if background { await environment.disconnectAll() } else { first.cancel() }
        await gate.release()
        do { _ = try await first.value; XCTFail("Old attempt must cancel") } catch {}
        if background {
            do { _ = try await second.value; XCTFail("Queued attempt must not outlive background teardown") } catch {}
            XCTAssertNil(environment.connectionStates[id])
            XCTAssertEqual(calls.withLock { $0 }, 1)
        } else {
            let connected = try await second.value
            XCTAssertEqual(connected, id)
            XCTAssertEqual(environment.connectionStates[id], .connected)
            XCTAssertEqual(calls.withLock { $0 }, 2)
        }
    }

    func testBackgroundFencesAllConcurrentPairingsBeforeAwaitingCleanup() async throws {
        let firstEnrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let secondEnrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr().replacingOccurrences(of: "gateway.example", with: "second.example"))
        let firstID = GatewayID(endpoint: firstEnrollment.origin), secondID = GatewayID(endpoint: secondEnrollment.origin)
        let firstGate = PairingGateConnection(gatewayID: firstID, holdDisconnect: true)
        let secondGate = PairingGateConnection(gatewayID: secondID, holdDisconnect: true)
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { _, _ in firstGate })
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(), connectionFactory: { _, _ in firstGate }, health: TestHealthAccumulator(), pairingConnectionFactory: { gateway, _ in gateway.id == firstID ? firstGate : secondGate }, pairingCredentialStore: credentials)
        let first = Task { try await environment.completePairing(firstEnrollment, confirmsTLSFirstUse: true) }
        let second = Task { try await environment.completePairing(secondEnrollment, confirmsTLSFirstUse: true) }
        await firstGate.waitUntilConnecting(); await secondGate.waitUntilConnecting()
        let teardown = Task { await environment.disconnectAll() }
        for _ in 0..<100 {
            let a = await firstGate.disconnects, b = await secondGate.disconnects
            if a + b > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await firstGate.release(); await secondGate.release()
        for _ in 0..<100 {
            if environment.connectionStates[firstID] == .connected || environment.connectionStates[secondID] == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(environment.connectionStates[firstID])
        XCTAssertNil(environment.connectionStates[secondID])
        await firstGate.releaseDisconnect(); await secondGate.releaseDisconnect()
        await teardown.value
        do { _ = try await first.value; XCTFail("First must cancel") } catch {}
        do { _ = try await second.value; XCTFail("Second must cancel") } catch {}
    }

    func testTrustCleanupAttemptsApprovalResetEvenWhenPinDeletionFails() async throws {
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let credentials = InMemoryCredentialStore()
        let pins = PairingFailingPinDeleteStore()
        let approval = PairingApprovalStore()
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .failure(.unreachable)) })
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), tlsPinStore: pins, tlsApprovalStore: approval, sessionList: TestSessionList(), connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .failure(.unreachable)) }, health: TestHealthAccumulator(), pairingConnectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, result: .failure(.unreachable)) }, pairingCredentialStore: credentials)
        do { _ = try await environment.completePairing(enrollment, confirmsTLSFirstUse: true); XCTFail("Injected failure") } catch {}
        let approved = await approval.approved
        XCTAssertFalse(approved, "Independent approval cleanup must run despite pin-store failure")
    }
    private actor PairingApprovalStore: TLSFirstUseApprovalStoring {
        var approved = false
        func approveFirstUse(for id: GatewayID) async throws { approved = true }
        func isFirstUseApproved(for id: GatewayID) async throws -> Bool { approved }
        func resetFirstUseApproval(for id: GatewayID) async throws { approved = false }
    }
    private actor PairingFailingPinDeleteStore: TLSPinStoring {
        func loadPin(for id: GatewayID) async throws -> SPKIFingerprint? { nil }
        func savePin(_ pin: SPKIFingerprint, for id: GatewayID) async throws {}
        func deletePin(for id: GatewayID) async throws { throw PinStoreError.unexpectedStatus(-1) }
    }

    func testPartialCredentialClearRetiresAuthenticatedConnection() async throws {
        let credentials = InMemoryCredentialStore()
        let records = PairingFailingRecordStore()
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { gateway, _ in RecordingConnection(gatewayID: gateway.id) }, recordStore: records)
        let enrollment = try PairingEnrollment.decode(EmbeddedTailnetUITests.qr())
        let gateway = try await registry.addGateway(.init(displayName: "Fixture", endpoint: enrollment.origin, authConfiguration: .init(strategy: .usernamePassword)))
        try await registry.saveCredential(enrollment.credential, for: gateway.id)
        let connection = RecordingConnection(gatewayID: gateway.id)
        let roster = FleetRosterService(registry: registry, credentials: credentials, sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id, profiles: []) })
        let environment = AppEnvironment(registry: registry, roster: roster, cache: try SwiftDataCacheStore.makeInMemory(), sessionList: TestSessionList(), connectionFactory: { _, _ in connection }, health: TestHealthAccumulator())
        await environment.load(); await environment.connect(to: gateway.id)
        await records.setFailWrites(true)
        do { try await environment.clearCredential(for: gateway.id); XCTFail("Metadata persistence failure expected") }
        catch {
            guard case GatewayRegistryError.recordStoreFailed = error else {
                XCTFail("Expected metadata persistence failure"); throw error
            }
        }
        let stored = try await credentials.loadCredential(for: gateway.id)
        XCTAssertNil(stored, "Credential delete has already succeeded")
        XCTAssertGreaterThan(connection.disconnectCount, 0, "A partial mutation must still retire authenticated sockets")
        XCTAssertNotEqual(environment.connectionStates[gateway.id], .connected)
    }
    private actor PairingFailingRecordStore: GatewayRecordStoring {
        var records: [String: StoredGatewayRecord] = [:]
        var failWrites = false
        func setFailWrites(_ value: Bool) { failWrites = value }
        func loadGatewayRecords() async throws -> [StoredGatewayRecord] { Array(records.values) }
        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
            if failWrites { throw GatewayRegistryError.recordStoreFailed("fixture write failure") }
            records[record.id] = record
        }
        func deleteGatewayRecord(id: GatewayID) async throws { records[id.rawValue] = nil }
    }

    private actor PairingSaveFailureStore: CredentialStoring {
        func loadCredential(for id: GatewayID) async throws -> GatewayCredential? { nil }
        func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws { throw CredentialStoreError.storeUnavailable("fixture failure") }
        func deleteCredential(for id: GatewayID) async throws {}
    }
    private actor PairingTestPinStore: TLSPinStoring {
        var pins: [GatewayID: SPKIFingerprint] = [:]
        func loadPin(for id: GatewayID) async throws -> SPKIFingerprint? { pins[id] }
        func savePin(_ pin: SPKIFingerprint, for id: GatewayID) async throws { pins[id] = pin }
        func deletePin(for id: GatewayID) async throws { pins[id] = nil }
    }

    private actor PairingGateConnection: GatewayConnectivityProviding {
        nonisolated let gatewayID: GatewayID
        nonisolated var status: GatewayStatus { .online }
        var started = false
        var readyWaiter: CheckedContinuation<Void, Never>?
        var connectWaiter: CheckedContinuation<Void, Never>?
        var disconnects = 0
        var holdDisconnect: Bool
        var disconnectWaiter: CheckedContinuation<Void, Never>?
        init(gatewayID: GatewayID, holdDisconnect: Bool = false) { self.gatewayID = gatewayID; self.holdDisconnect = holdDisconnect }
        func connect() async throws {
            started = true
            await withCheckedContinuation { continuation in
                connectWaiter = continuation
                readyWaiter?.resume(); readyWaiter = nil
            }
        }
        func waitUntilConnecting() async {
            if started { return }
            await withCheckedContinuation { readyWaiter = $0 }
        }
        func release() { connectWaiter?.resume(); connectWaiter = nil }
        func disconnect() async {
            disconnects += 1
            if holdDisconnect && disconnects == 1 { await withCheckedContinuation { disconnectWaiter = $0 } }
        }
        func releaseDisconnect() { holdDisconnect = false; disconnectWaiter?.resume(); disconnectWaiter = nil }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "Fixture") }
    }

    // MARK: Fixture seams

    private struct TestConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        let result: Result<Void, GatewayConnectivityError>
        /// A successful scripted connect leaves the gateway online (the
        /// runtime reads this after `connect()` returns).
        var status: GatewayStatus { .online }

        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "test", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {
            try result.get()
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    /// A connection that throws `invalidState` on a SECOND connect — exactly
    /// what the real transport does (`GatewayWebSocketTransport.connect()` on
    /// an open socket). Counts calls so the test can prove the runtime never
    /// drives a second connect on an already-connected gateway.
    private final class InvalidStateOnSecondConnect: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        /// Single-threaded test fixture (all access on the main actor); marked
        /// `nonisolated(unsafe)` so the Sendable-conforming class can count
        /// connect calls without lock machinery.
        nonisolated(unsafe) private(set) var connectCount = 0
        var status: GatewayStatus { .online }

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }

        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "test", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {
            connectCount += 1
            if connectCount > 1 {
                throw GatewayConnectivityError.invalidState("connect() from open")
            }
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    private struct TestRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        let profiles: [ProfileDescriptor]
        var status: GatewayStatus = .online
        /// Scripted `profiles.list` failure (e.g. an unreachable gateway) so a
        /// test can drive a partial-outage refresh deterministically.
        let rosterError: RosterError?

        init(
            gatewayID: GatewayID,
            profiles: [ProfileDescriptor],
            status: GatewayStatus = .online,
            rosterError: RosterError? = nil
        ) {
            self.gatewayID = gatewayID
            self.profiles = profiles
            self.status = status
            self.rosterError = rosterError
        }

        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] {
            if let rosterError { throw rosterError }
            return profiles
        }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    /// Scripted read-only `session.list` double for U2 Bot-detail tests.
    private struct TestSessionList: SessionListProviding {
        let sessions: [SessionSummary]
        let error: RosterError?

        init(sessions: [SessionSummary] = [], error: RosterError? = nil) {
            self.sessions = sessions
            self.error = error
        }

        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
            if let error { throw error }
            return sessions
        }
    }

    /// H2: inert connection-health accumulator double — records nothing, keeps
    /// whatever the test seeds, so AppEnvironment tests exercise the runtime
    /// wiring without touching SwiftData or the transport. Uses the
    /// async-safe scoped `OSAllocatedUnfairLock` pattern.
    private final class TestHealthAccumulator: ConnectionHealthAccumulating, @unchecked Sendable {
        private struct State {
            var stored: [GatewayID: GatewayHealthStats] = [:]
            var didRehydrate = false
        }
        private let lock = OSAllocatedUnfairLock<State>(initialState: State())

        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] {
            lock.withLock { $0.stored }
        }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? {
            lock.withLock { $0.stored[gatewayID] }
        }
        func rehydrate(gatewayIDs: [GatewayID]) async {
            lock.withLock { $0.didRehydrate = true }
        }
        func forget(gatewayID: GatewayID) async {
            lock.withLock { $0.stored[gatewayID] = nil }
        }
        /// Seed a snapshot for a gateway (test-only; exercises the observable
        /// `healthStats` publishing path).
        func seed(_ stats: GatewayHealthStats, for gatewayID: GatewayID) {
            lock.withLock { $0.stored[gatewayID] = stats }
        }
        var rehydrated: Bool {
            lock.withLock { $0.didRehydrate }
        }
    }

    /// Build a runtime over scripted seams. `seed` registers gateways first
    /// so `load()` finds a non-empty registry (production behavior).
    private func makeEnvironment(
        gateways: [GatewayRegistration],
        profiles: [ProfileDescriptor] = [],
        sessionList: any SessionListProviding = TestSessionList()
    ) async -> (AppEnvironment, GatewayRegistryService) {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: profiles)
            }
        )
        let cache = try! SwiftDataCacheStore.makeInMemory()
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            sessionList: sessionList,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            },
            health: TestHealthAccumulator(),
            seedRegistrations: gateways
        )
        await environment.load()
        return (environment, registry)
    }

    private func registration(_ id: String, name: String) -> GatewayRegistration {
        GatewayRegistration(
            id: GatewayID(rawValue: id),
            displayName: name,
            endpoint: URL(string: "http://127.0.0.1:\(id.count)")!
        )
    }

    // MARK: Load / registry seam

    func testLoadSeedsAndPublishesGateways() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
            registration("render-box", name: "Render Box"),
        ])

        XCTAssertEqual(environment.gateways.map(\.id.rawValue).sorted(),
                       ["render-box", "workstation"])
        // Fresh registry entries are idle until a connect attempt.
        XCTAssertEqual(environment.connectionStates[GatewayID(rawValue: "workstation")], .idle)
        XCTAssertEqual(environment.connectionStates[GatewayID(rawValue: "render-box")], .idle)
    }

    func testLoadSeedsOnlyWhenRegistryEmpty() async {
        // Registry pre-seeded with one gateway → seedRegistrations are NOT
        // applied (user-managed fleet is authoritative).
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        _ = try! await registry.addGateway(registration("existing", name: "Existing"))
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            },
            health: TestHealthAccumulator(),
            seedRegistrations: [registration("workstation", name: "Workstation")]
        )
        await environment.load()

        XCTAssertEqual(environment.gateways.map(\.id.rawValue), ["existing"])
    }

    // MARK: H2 — connection health wiring (observable publishing)

    func testHealthStatsRehydratePublishAndForget() async {
        let health = TestHealthAccumulator()
        let id = GatewayID(rawValue: "workstation")
        let seeded = GatewayHealthStats(
            currentState: .offline,
            firstObservedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastTransitionAt: Date(timeIntervalSince1970: 1_700_000_100),
            connectedMilliseconds: 30_000,
            disconnectedMilliseconds: 10_000,
            reconnectCount: 1,
            lastDisconnectReason: "normal closure"
        )
        health.seed(seeded, for: id)

        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        _ = try! await registry.addGateway(registration("workstation", name: "Workstation"))
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            },
            health: health,
            seedRegistrations: []
        )

        await environment.load()
        XCTAssertTrue(health.rehydrated, "load() must rehydrate the accumulator")
        XCTAssertEqual(environment.healthStats[id]?.reconnectCount, 1,
                       "persisted health stats published into the observable state")
        XCTAssertEqual(environment.healthStats[id]?.uptimePercentage ?? 0, 75.0, accuracy: 0.01)

        // Removing the gateway forgets its health stats.
        try? await environment.removeGateway(id)
        XCTAssertNil(environment.healthStats[id], "removal drops the health snapshot")
    }

    // MARK: Connection lifecycle — observable states

    func testConnectTransitionsConnectingToConnected() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        let id = GatewayID(rawValue: "workstation")
        XCTAssertEqual(environment.connectionStates[id], .idle)

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "connect() succeeds → observable state is connected")
    }

    func testConnectFailureClassifiesOffline() async {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .failure(.unreachable))
            }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .failure(.unreachable))
            },
            health: TestHealthAccumulator(),
            seedRegistrations: [registration("workstation", name: "Workstation")]
        )
        await environment.load()

        let id = GatewayID(rawValue: "workstation")
        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .failed(.offline),
                       "unreachable connect → classified offline, never throws to UI")
    }

    func testDisconnectIsSafeAndObservable() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        let id = GatewayID(rawValue: "workstation")

        await environment.disconnect(from: id)
        XCTAssertEqual(environment.connectionStates[id], .disconnected,
                       "disconnect before any connect is safe (spec §31)")

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        await environment.disconnect(from: id)
        XCTAssertEqual(environment.connectionStates[id], .disconnected)
    }

    func testDisconnectAllTearsDownEveryActiveConnection() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
            registration("laptop", name: "Laptop"),
        ])
        let workstation = GatewayID(rawValue: "workstation")
        let laptop = GatewayID(rawValue: "laptop")

        await environment.connect(to: workstation)
        await environment.connect(to: laptop)
        XCTAssertEqual(environment.connectionStates[workstation], .connected)
        XCTAssertEqual(environment.connectionStates[laptop], .connected)

        await environment.disconnectAll()

        XCTAssertEqual(environment.connectionStates[workstation], .disconnected)
        XCTAssertEqual(environment.connectionStates[laptop], .disconnected)
    }

    func testReconnectTearsDownThenConnects() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        let id = GatewayID(rawValue: "workstation")

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        await environment.reconnect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "reconnect leaves the gateway connected")
    }

    func testConnectWhileAlreadyConnectedIsNoOp() async {
        // Faithful Release repro: the real transport throws invalidState on a
        // second connect. The runtime must NEVER drive a second connect on an
        // already-connected gateway — connect-while-connected is a no-op and
        // the observable state stays .connected (never flips to .failed).
        let connection = InvalidStateOnSecondConnect(gatewayID: GatewayID(rawValue: "workstation"))
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in connection }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in connection },
            health: TestHealthAccumulator(),
            seedRegistrations: [registration("workstation", name: "Workstation")]
        )
        await environment.load()
        let id = GatewayID(rawValue: "workstation")

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        XCTAssertEqual(connection.connectCount, 1)

        // Second connect while already connected: guard short-circuits, the
        // transport is never touched, and the state stays connected.
        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "connect-while-connected must stay .connected")
        XCTAssertEqual(connection.connectCount, 1,
                       "runtime must not drive a second connect on an open connection")
    }

    // MARK: Roster seam (M8 union aggregation observable)

    func testRefreshRosterPublishesBots() async {
        let profile = ProfileDescriptor(
            name: "default", path: "~/.hermes/profiles/default", isDefault: true,
            model: "hermes", provider: "nous", displayName: "Default",
            skillCount: 12, hasAvatar: true
        )
        let (environment, _) = await makeEnvironment(
            gateways: [registration("workstation", name: "Workstation")],
            profiles: [profile]
        )

        XCTAssertTrue(environment.bots(on: GatewayID(rawValue: "workstation")).isEmpty,
                      "no snapshot before refresh → fail closed")

        await environment.refreshRoster()

        let bots = environment.bots(on: GatewayID(rawValue: "workstation"))
        XCTAssertEqual(bots.map(\.profileSlug.rawValue), ["default"])
        XCTAssertEqual(bots.first?.route.gatewayID.rawValue, "workstation",
                       "owning gateway provenance preserved")
        XCTAssertNotNil(environment.rosterSnapshot)
        XCTAssertFalse(environment.isRefreshing)
    }

    // MARK: Cache seam (M10 behind FleetCore seam)

    func testCacheSeamIsWiredObservable() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        // Fresh in-memory cache → zero watermarks, observable on the runtime.
        XCTAssertEqual(environment.cachedWatermarkCount, 0)
    }

    // MARK: U2 — Gateway registry management over the seam

    func testTransportChangeRetiresOldGatewayConnection() async throws {
        let id = GatewayID(rawValue: "fixture")
        let (environment, _) = await makeEnvironment(gateways: [GatewayRegistration(
            id: id, displayName: "Fixture", endpoint: URL(string: "https://host.example.ts.net")!)])
        await environment.connect(to: id)
        XCTAssertNotNil(environment.connectionStates[id])
        _ = try await environment.updateGateway(id, edits: GatewayEdit(transport: .embeddedTailscale))
        XCTAssertEqual(environment.connectionStates[id], .idle, "Old system-network sessions must not survive changing transport")
    }

    func testUpdateGatewayAppliesEdits() async throws {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        let id = GatewayID(rawValue: "workstation")

        let updated = try await environment.updateGateway(
            id,
            edits: GatewayEdit(
                displayName: "Workstation Pro",
                endpoint: URL(string: "http://127.0.0.1:8643")!
            )
        )

        XCTAssertEqual(updated.displayName, "Workstation Pro")
        XCTAssertEqual(updated.endpoint?.absoluteString, "http://127.0.0.1:8643")
        // The observable gateway list reflects the edit.
        XCTAssertEqual(environment.gateways.first?.displayName, "Workstation Pro")
    }

    func testRemoveGatewayClearsObservableState() async throws {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        let id = GatewayID(rawValue: "workstation")

        try await environment.removeGateway(id)

        XCTAssertTrue(environment.gateways.isEmpty)
        XCTAssertNil(environment.connectionStates[id])
        XCTAssertNil(environment.testResults[id])
    }

    // MARK: P1-8 — removal retires session resources (disconnects the live connection)

    /// A connection double that records `disconnect()` invocations.
    private final class RecordingConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        nonisolated(unsafe) private(set) var disconnectCount = 0
        var status: GatewayStatus { .online }
        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async { disconnectCount += 1 }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    func testRemoveGatewayDisconnectsActiveConnection() async throws {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecordingConnection(gatewayID: id)
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { _, _ in connection }
        )
        _ = try! await registry.addGateway(registration("workstation", name: "Workstation"))
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { _, _ in connection },
            health: TestHealthAccumulator(),
            seedRegistrations: []
        )
        await environment.load()
        await environment.connect(to: id)
        XCTAssertEqual(connection.disconnectCount, 0)

        try await environment.removeGateway(id)

        XCTAssertEqual(connection.disconnectCount, 1,
                       "P1-8: removal must disconnect the live connection")
        XCTAssertTrue(environment.gateways.isEmpty)
    }

    // MARK: U2 — test connection (reachable/unreachable per §13, observable)

    func testTestConnectionStoresReachableResult() async throws {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        let id = GatewayID(rawValue: "workstation")

        try await environment.testConnection(to: id)

        let result = try XCTUnwrap(environment.testResults[id])
        XCTAssertEqual(result.status, .online, "healthy probe → online (reachable)")
        XCTAssertTrue(environment.testingGatewayIDs.isEmpty)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "reachable probe reflects into the observable lifecycle")
    }

    func testTestConnectionClassifiesUnreachableWithoutThrowing() async throws {
        // Registry probe factory throws unreachable → classified .offline and
        // stored, never thrown to the UI (spec §31 reachable/unreachable).
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .failure(.unreachable))
            }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .failure(.unreachable))
            },
            health: TestHealthAccumulator(),
            seedRegistrations: [registration("workstation", name: "Workstation")]
        )
        await environment.load()
        let id = GatewayID(rawValue: "workstation")

        try await environment.testConnection(to: id)  // no throw

        let result = try XCTUnwrap(environment.testResults[id])
        XCTAssertEqual(result.status, .offline, "unreachable probe → classified offline")
        XCTAssertEqual(environment.connectionStates[id], .failed(.offline))
    }

    func testTestConnectionThrowsForAbsentGateway() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        do {
            try await environment.testConnection(to: GatewayID(rawValue: "ghost"))
            XCTFail("expected notFound for absent gateway")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .notFound(GatewayID(rawValue: "ghost")))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: U2 — auth config entry (M7 credential flow, observable)

    func testSaveAndClearCredentialIsObservable() async throws {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        let id = GatewayID(rawValue: "workstation")

        let initialHas = await environment.hasCredential(for: id)
        XCTAssertFalse(initialHas)

        try await environment.saveCredential(GatewayCredential(rawValue: "fixture-token"), for: id)

        let storedHas = await environment.hasCredential(for: id)
        XCTAssertTrue(storedHas)
        XCTAssertEqual(environment.gateways.first?.authConfigured, true)
        XCTAssertEqual(environment.gateways.first?.authConfiguration.credentialStored, true)

        try await environment.clearCredential(for: id)

        let afterClear = await environment.hasCredential(for: id)
        XCTAssertFalse(afterClear)
        XCTAssertEqual(environment.gateways.first?.authConfigured, false)
    }

    // MARK: U2 — Bot detail session list (read-only `session.list` seam)

    func testLoadSessionsPublishesSessionsForRoute() async {
        let session = SessionSummary(
            id: "s1", title: "Fleet setup", preview: "hello",
            startedAt: 1_754_000_000, messageCount: 6, source: "ios"
        )
        let (environment, _) = await makeEnvironment(
            gateways: [registration("workstation", name: "Workstation")],
            sessionList: TestSessionList(sessions: [session])
        )
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )

        XCTAssertNil(environment.sessions(for: route), "no fetch yet → fail closed nil")
        await environment.loadSessions(for: route)

        XCTAssertEqual(environment.sessions(for: route)?.map(\.id), ["s1"])
        XCTAssertNil(environment.sessionReadErrors[route])
        XCTAssertFalse(environment.loadingRoutes.contains(route))
    }

    func testLoadSessionsRecordsClassifiedError() async {
        let (environment, _) = await makeEnvironment(
            gateways: [registration("workstation", name: "Workstation")],
            sessionList: TestSessionList(error: .notConnected)
        )
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )

        await environment.loadSessions(for: route)

        XCTAssertNil(environment.sessions(for: route))
        XCTAssertEqual(environment.sessionReadErrors[route], "gateway not connected",
                       "classified read error surfaced non-secret, no crash")
    }

    // MARK: U2 — union roster partial availability (M8 aggregation observable)

    func testRosterOutcomeClassifiesPartialOutage() async throws {
        // One reachable + one unreachable gateway: refresh never throws, the
        // reachable gateway's bots stay in the union, and the unreachable one
        // is classified (spec §31 / §30).
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        _ = try! await registry.addGateway(registration("workstation", name: "Workstation"))
        _ = try! await registry.addGateway(registration("arch", name: "Arch"))

        let reachableProfile = ProfileDescriptor(
            name: "default", path: "~/.hermes/profiles/default", isDefault: true,
            model: "hermes", provider: "nous", displayName: "Default"
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                if gateway.id.rawValue == "arch" {
                    return TestRosterSession(
                        gatewayID: gateway.id,
                        profiles: [],
                        status: .offline,
                        rosterError: .notConnected)
                }
                return TestRosterSession(gatewayID: gateway.id, profiles: [reachableProfile])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            },
            health: TestHealthAccumulator()
        )
        await environment.load()
        await environment.refreshRoster()

        let snapshot = try XCTUnwrap(environment.rosterSnapshot)
        XCTAssertEqual(snapshot.reachableGateways.map(\.id.rawValue), ["workstation"])
        XCTAssertEqual(snapshot.unreachableGateways.map(\.id.rawValue), ["arch"])
        XCTAssertEqual(environment.bots(on: GatewayID(rawValue: "workstation")).count, 1,
                       "reachable gateway's bots stay available during partial outage")
        XCTAssertTrue(environment.bots(on: GatewayID(rawValue: "arch")).isEmpty)
        if case .failed(let status, _) = snapshot.outcome(for: GatewayID(rawValue: "arch")) {
            XCTAssertEqual(status, .offline)
        } else {
            XCTFail("expected arch classified failed")
        }
    }

    // MARK: t_e77c614c — roster refresh generation fencing

    /// A `FleetRosterProviding` double whose refresh can be held in flight
    /// (until `release()`) and returns the snapshot scripted at CALL time, so
    /// a test can distinguish a stale refresh's result from a newer one.
    private final class GatedRoster: FleetRosterProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshot: FleetRosterSnapshot
        private var _gated = false
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(snapshot: FleetRosterSnapshot, gated: Bool) {
            self._snapshot = snapshot
            self._gated = gated
        }

        // NSLock is unavailable from async contexts — confine it to these
        // synchronous helpers.
        private func captureSnapshot() -> FleetRosterSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return _snapshot
        }

        private func shouldWait() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return _gated && !opened
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }

        func refreshRoster() async -> FleetRosterSnapshot {
            let snapshot = captureSnapshot()
            if shouldWait() {
                await withCheckedContinuation { continuation in
                    park(continuation)
                }
            }
            return snapshot
        }

        func update(_ snapshot: FleetRosterSnapshot) {
            lock.lock()
            _snapshot = snapshot
            lock.unlock()
        }

        func release() {
            lock.lock()
            opened = true
            let resumed = waiters
            waiters = []
            lock.unlock()
            resumed.forEach { $0.resume() }
        }
    }

    /// Rapid retaps: an older in-flight refresh completing AFTER a newer one
    /// must NOT overwrite `rosterSnapshot` — observable state reflects only
    /// the most recent refresh, and `isRefreshing` settles false when the
    /// newest completes.
    func testStaleRosterRefreshDoesNotOverwriteNewerSnapshot() async {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        _ = try! await registry.addGateway(registration("workstation", name: "Workstation"))
        let staleSnapshot = FleetRosterSnapshot(
            roster: FleetRoster(gateways: [
                FleetGateway(
                    id: GatewayID(rawValue: "workstation"),
                    displayName: "STALE-display-name"
                ),
            ]),
            gatewayOutcomes: [
                GatewayID(rawValue: "workstation"): .loaded(profileCount: 1)
            ]
        )
        let freshSnapshot = FleetRosterSnapshot(
            roster: FleetRoster(gateways: [
                FleetGateway(
                    id: GatewayID(rawValue: "workstation"),
                    displayName: "FRESH-display-name"
                ),
            ]),
            gatewayOutcomes: [
                GatewayID(rawValue: "workstation"): .loaded(profileCount: 2)
            ]
        )
        let gated = GatedRoster(snapshot: staleSnapshot, gated: true)
        let cache = try! SwiftDataCacheStore.makeInMemory()
        let environment = AppEnvironment(
            registry: registry,
            roster: gated,
            cache: cache,
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            },
            health: TestHealthAccumulator()
        )
        await environment.load()

        // Refresh #1 (held in flight) captured the STALE snapshot at call time.
        gated.update(staleSnapshot)
        async let staleRefresh: Void = environment.refreshRoster()
        // Give refresh #1 a hop to enter the roster seam.
        try? await Task.sleep(for: .milliseconds(10))

        // Refresh #2 starts and completes with the FRESH snapshot — it
        // supersedes #1.
        gated.update(freshSnapshot)
        gated.release() // refresh #2 (and any later) pass through ungated
        await environment.refreshRoster()

        XCTAssertEqual(environment.rosterSnapshot?.roster.allGateways.first?.displayName,
                       "FRESH-display-name",
                       "the newest refresh must own observable state")
        XCTAssertFalse(environment.isRefreshing,
                       "isRefreshing settles false when the newest refresh completes")

        // The stale refresh lands now — must be dropped.
        // (release() above already opened the gate for it; give it a hop.)
        _ = await staleRefresh
        XCTAssertEqual(environment.rosterSnapshot?.roster.allGateways.first?.displayName,
                       "FRESH-display-name",
                       "stale (superseded) refresh must not overwrite newer state")
    }

    /// In-order (non-raced) refresh behaves exactly as before: snapshot
    /// applied, `isRefreshing` false after.
    func testInOrderRosterRefreshUnchanged() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("workstation", name: "Workstation"),
        ])
        await environment.refreshRoster()
        XCTAssertNotNil(environment.rosterSnapshot)
        XCTAssertFalse(environment.isRefreshing)
    }

    // MARK: F1 — gateway-level Create Room gate (zero-room first use)

    /// Scripted room source answering a gateway-level capability probe.
    private struct CapabilityProbeSource: FleetRoomSourceProviding {
        let capability: GroupsCreateCapability
        func rooms() async -> [FleetRoom] { [] }
        func createRoomCapability() async -> GroupsCreateCapability { capability }
    }

    /// A source whose probe answer can flip between loads (last-known-truth
    /// test). OSAllocatedUnfairLock — NSLock is banned in async contexts.
    private final class FlippingProbeSource: FleetRoomSourceProviding, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var _capability: GroupsCreateCapability
        init(_ capability: GroupsCreateCapability) { _capability = capability }
        func setCapability(_ capability: GroupsCreateCapability) {
            lock.withLock { _capability = capability }
        }
        func rooms() async -> [FleetRoom] { [] }
        func createRoomCapability() async -> GroupsCreateCapability {
            lock.withLock { _capability }
        }
    }

    private func makeRoomEnvironment(
        source: any FleetRoomSourceProviding
    ) async -> (AppEnvironment, GatewayID) {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let gateway = registration("fresh-gateway", name: "Fresh Gateway")
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            },
            roomSourceFactory: { _ in source },
            health: TestHealthAccumulator(),
            seedRegistrations: [gateway]
        )
        await environment.load()
        return (environment, gateway.id ?? GatewayID(rawValue: "fresh-gateway"))
    }

    /// F1 core case: a fully groups-capable gateway hosting ZERO rooms must
    /// still offer Create Room — the first room on a fresh gateway is
    /// creatable from Fleet.
    func testCreateRoomOfferedOnZeroRoomCapableGateway() async {
        let (environment, gatewayID) = await makeRoomEnvironment(
            source: CapabilityProbeSource(capability: .supported))
        await environment.loadRooms()
        XCTAssertTrue(environment.rooms(for: gatewayID).isEmpty,
                      "fixture: zero hosted rooms (fresh gateway, first use)")
        XCTAssertEqual(environment.canCreateRoomsByGateway[gatewayID], true,
                       "probe truth is persisted at the gateway level")
        XCTAssertTrue(environment.canCreateRooms(on: gatewayID),
                      "F1: capable gateway with ZERO rooms must still offer Create Room")
    }

    /// Old gateway without groups.*: honest absence — no dead button.
    func testCreateRoomHiddenOnUnsupportedGateway() async {
        let (environment, gatewayID) = await makeRoomEnvironment(
            source: CapabilityProbeSource(capability: .unsupported))
        await environment.loadRooms()
        XCTAssertEqual(environment.canCreateRoomsByGateway[gatewayID], false)
        XCTAssertFalse(environment.canCreateRooms(on: gatewayID),
                       "unsupported gateway must not offer Create Room")
    }

    /// `.unknown` (probe transport failure) never flips the gate: the
    /// last-known capability stands until a definitive answer arrives.
    func testUnknownProbeKeepsLastKnownCapabilityTruth() async {
        let source = FlippingProbeSource(.supported)
        let (environment, gatewayID) = await makeRoomEnvironment(source: source)

        await environment.loadRooms()
        XCTAssertTrue(environment.canCreateRooms(on: gatewayID),
                      "capable gateway opens the gate on the first probe")

        // Probe starts failing (gateway unreachable): last-known truth stands.
        source.setCapability(.unknown)
        await environment.loadRooms()
        XCTAssertTrue(environment.canCreateRooms(on: gatewayID),
                      ".unknown must not hide Create Room on a capable gateway")

        // A definitive downgrade is honest truth (downgrade allowed).
        source.setCapability(.unsupported)
        await environment.loadRooms()
        XCTAssertFalse(environment.canCreateRooms(on: gatewayID),
                       "definitive unsupported answer closes the gate")
    }

    /// Never-probed gateway (.unknown) with a hosted room advertising
    /// groups.create + driver: the legacy room-row evidence still applies.
    func testCreateGateFallsBackToRoomRowEvidenceWhenNeverProbed() async {
        let gatewayID = GatewayID(rawValue: "fresh-gateway")
        let capableRoom = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: "room-1"),
            name: "Research Crew",
            members: [],
            hosted: HostedRoomState(
                authorityGatewayID: gatewayID.rawValue,
                authorityEpoch: 1,
                advertisedMethods: ["groups.create", "groups.send"],
                driverAvailable: true))
        struct RoomRowSource: FleetRoomSourceProviding {
            let room: FleetRoom
            func rooms() async -> [FleetRoom] { [room] }
            // createRoomCapability() defaults to .unknown
        }
        let (environment, _) = await makeRoomEnvironment(
            source: RoomRowSource(room: capableRoom))
        await environment.loadRooms()
        XCTAssertTrue(environment.canCreateRooms(on: gatewayID),
                      "unprobed gateway with an advertising hosted room keeps the legacy path")
    }
}


/// A real bounded HTTP + RFC6455 fixture. Authentication is checked by the
/// receiving server, not by a mocked client response or a no-op connect.
private final class PairingWireFixture: @unchecked Sendable {
    private struct State {
        var paths: [String] = []
        var connections: [NWConnection] = []
        var paired = false
        var revoked = false
        var ticket = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let listener: NWListener
    var listeningPort: UInt16 { listener.port!.rawValue }
    var paths: [String] { state.withLock { $0.paths } }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
                if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.state.withLock { $0.connections.append(connection) }
                connection.start(queue: .global())
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: .global())
        }
    }
    func primeSession() { state.withLock { $0.paired = true } }
    func revoke() {
        state.withLock { $0.paired = false; $0.ticket = false; $0.revoked = true }
        state.withLock { $0.connections }.forEach { $0.cancel() }
    }
    func stop() {
        listener.cancel()
        state.withLock { $0.connections }.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, ended, error in
            guard let self else { return }
            var data = buffer
            data.append(bytes ?? Data())
            guard data.count <= 16384, error == nil else { connection.cancel(); return }
            if let range = data.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: data[..<range.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let request = lines[0].split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2 { headers[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard data.count >= range.upperBound + length else {
                    self.receive(connection, buffer: data); return
                }
                guard request.count == 3 else { connection.cancel(); return }
                self.respond(connection, method: String(request[0]), target: String(request[1]), headers: headers,
                    body: Data(data[range.upperBound..<(range.upperBound + length)]))
            } else if !ended { self.receive(connection, buffer: data) }
        }
    }
    private func respond(_ connection: NWConnection, method: String, target: String, headers: [String: String], body: Data) {
        let url = URL(string: "http://fixture" + target)!
        let path = url.path
        state.withLock { $0.paths.append(path) }
        var payload = "{}"
        var allowed = false
        var extraHeaders = ""
        if path == "/api/auth/providers", method == "GET" {
            allowed = true
            payload = #"{"providers":[{"name":"basic","supports_password":true}]}"#
        } else if path == "/auth/password-login", method == "POST", !state.withLock({ $0.revoked }),
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  object["provider"] == "basic", object["username"] == "fixture-user", object["password"] == "NOT-A-CREDENTIAL" {
            allowed = true
            state.withLock { $0.paired = true }
            extraHeaders = "Set-Cookie: hermes_session_at=fixture-native-session; HttpOnly; Path=/\r\n"
            payload = #"{"ok":true,"next":"/"}"#
        } else if path == "/api/auth/ws-ticket", method == "POST", !state.withLock({ $0.revoked }),
                  (state.withLock({ $0.paired }) && headers["cookie"] == "hermes_session_at=fixture-native-session") || headers["x-hermes-session-token"] == "fixture-native-token" {
            allowed = true
            state.withLock { $0.ticket = true }
            payload = #"{"ticket":"fixture-single-use-ticket","ttl_seconds":30}"#
        } else if path == "/api/ws", method == "GET",
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "ticket", value: "fixture-single-use-ticket")) == true,
                  let key = headers["sec-websocket-key"] {
            let consumed = state.withLock { value in
                guard value.ticket else { return false }
                value.ticket = false
                return true
            }
            if consumed {
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                var response = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
                let ready = Data(ConversationFixtureLoopTests.readyFrame().utf8)
                response.append(contentsOf: [0x81, 126, UInt8(ready.count >> 8), UInt8(ready.count & 255)])
                response.append(ready)
                connection.send(content: response, completion: .contentProcessed { _ in })
                return
            }
        }
        let content = Data(payload.utf8)
        var response = Data("HTTP/1.1 \(allowed ? 200 : 401) Result\r\n\(extraHeaders)Content-Type: application/json\r\nContent-Length: \(content.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(content)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
