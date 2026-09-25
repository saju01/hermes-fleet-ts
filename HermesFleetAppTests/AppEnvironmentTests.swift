import XCTest
import os
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
