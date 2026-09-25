import XCTest
import os
import FleetCore
@testable import FleetNetworking

/// P0-4 (t_e32529e8): the registry service must WRITE THROUGH every durable
/// gateway mutation to the injected `GatewayRecordStoring` — a gateway added
/// through the UI is persisted IMMEDIATELY, regardless of connection state —
/// and `restorePersistedGateways()` must rebuild the in-memory registry from
/// the store on launch (never-connected entries included, marked
/// disconnected, auth flags re-derived from the credential store).
final class GatewayRecordWriteThroughTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "gateway.example.invalid:9120")
    private let endpoint = URL(string: "https://gateway.example.invalid:9120")!

    // MARK: fixtures

    /// In-memory `GatewayRecordStoring` local to this target.
    private final class TestRecordStore: GatewayRecordStoring, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String: StoredGatewayRecord]>(initialState: [:])
        private(set) var saveCount = 0

        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
            lock.withLock { $0[record.id] = record }
            saveCount += 1
        }
        func deleteGatewayRecord(id: GatewayID) async throws {
            lock.withLock { $0.removeValue(forKey: id.rawValue) }
        }
        func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
            lock.withLock { $0.values.sorted { $0.id < $1.id } }
        }
    }

    /// In-memory credential store (M0 boundary: no FleetSecurity import).
    private final class TestCredentialStore: CredentialStoring, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            lock.withLock { $0[gatewayID.rawValue] = credential.rawValue }
        }
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            lock.withLock { $0[gatewayID.rawValue].map { GatewayCredential(rawValue: $0) } }
        }
        func deleteCredential(for gatewayID: GatewayID) async throws {
            lock.withLock { $0.removeValue(forKey: gatewayID.rawValue) }
        }
    }

    private func makeService(
        records: TestRecordStore = TestRecordStore(),
        credentials: TestCredentialStore = TestCredentialStore()
    ) async -> (GatewayRegistryService, TestRecordStore, TestCredentialStore) {
        let service = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                StubOfflineConnection(gatewayID: gateway.id)
            },
            recordStore: records
        )
        return (service, records, credentials)
    }

    /// A connection stub whose connect always fails offline — proves
    /// persistence fires WITHOUT any successful connection.
    private struct StubOfflineConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {
            throw GatewayConnectivityError.connectionFailed("scripted offline")
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    // MARK: persist-on-Add (the P0-4 core)

    func testEmbeddedRegistrationRejectsPublicAndCleartextEndpoints() async throws {
        for raw in ["https://public.example.com", "http://host.example.ts.net", "https://localhost", "https://host.example.ts.net.evil.invalid"] {
            let (service, _, _) = await makeService()
            do {
                _ = try await service.addGateway(GatewayRegistration(displayName: "Fixture", endpoint: URL(string: raw)!, transport: .embeddedTailscale))
                XCTFail("Embedded routing admitted unsafe endpoint")
            } catch { }
        }
        let (service, records, _) = await makeService()
        let added = try await service.addGateway(GatewayRegistration(displayName: "Fixture", endpoint: URL(string: "https://host.example.ts.net")!, transport: .embeddedTailscale))
        XCTAssertEqual(added.transport, .embeddedTailscale)
        let loaded = try await records.loadGatewayRecords()
        XCTAssertEqual(loaded.first?.transport, .embeddedTailscale)
    }

    func testEmbeddedTransportRestoresAndSurvivesEdit() async throws {
        let records = TestRecordStore()
        try await records.saveGatewayRecord(StoredGatewayRecord(
            id: gatewayID.rawValue, displayName: "Fixture", endpoint: "https://host.example.ts.net",
            transport: .embeddedTailscale))
        let (service, _, _) = await makeService(records: records)
        _ = try await service.restorePersistedGateways()
        _ = try await service.updateGateway(gatewayID, edits: GatewayEdit(displayName: "Renamed"))
        let loaded = try await records.loadGatewayRecords()
        XCTAssertEqual(loaded.first?.transport, .embeddedTailscale)
    }

    func testAddPersistsRecordImmediatelyWithoutConnection() async throws {
        let (service, records, _) = await makeService()

        _ = try await service.addGateway(GatewayRegistration(
            displayName: "Lab Node",
            endpoint: endpoint,
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: false)
        ))

        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(stored.count, 1, "Add must write through to the record store")
        XCTAssertEqual(stored.first?.id, gatewayID.rawValue)
        XCTAssertEqual(stored.first?.displayName, "Lab Node")
        XCTAssertEqual(stored.first?.endpoint, endpoint.absoluteString)
        XCTAssertEqual(stored.first?.authConfiguration.strategy, .usernamePassword)
    }

    func testAddWithCredentialMarksRecordCredentialStored() async throws {
        let (service, records, _) = await makeService()

        let gateway = try await service.addGateway(GatewayRegistration(
            displayName: "Lab Node",
            endpoint: endpoint
        ))
        try await service.saveCredential(
            GatewayCredential(rawValue: "user:fake-low-entropy-pw"),
            for: gateway.id
        )

        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(
            stored.first?.authConfiguration.credentialStored, true,
            "saveCredential must update the persisted record"
        )
        XCTAssertEqual(stored.first?.authConfigured, true)
    }

    // MARK: edit / remove write-through

    func testUpdateWritesThroughRenamedRecord() async throws {
        let (service, records, _) = await makeService()
        _ = try await service.addGateway(GatewayRegistration(displayName: "Old", endpoint: endpoint))

        _ = try await service.updateGateway(
            gatewayID,
            edits: GatewayEdit(displayName: "New", endpoint: nil, authConfiguration: nil)
        )

        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.displayName, "New")
    }

    func testRemoveDeletesPersistedRecord() async throws {
        let (service, records, _) = await makeService()
        _ = try await service.addGateway(GatewayRegistration(displayName: "Lab Node", endpoint: endpoint))

        try await service.removeGateway(gatewayID)

        let stored = try await records.loadGatewayRecords()
        XCTAssertTrue(stored.isEmpty, "remove must delete the persisted record")
    }

    func testClearCredentialUpdatesPersistedRecord() async throws {
        let (service, records, _) = await makeService()
        let gateway = try await service.addGateway(GatewayRegistration(displayName: "Lab Node", endpoint: endpoint))
        try await service.saveCredential(GatewayCredential(rawValue: "user:fake"), for: gateway.id)

        try await service.clearCredential(for: gateway.id)

        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(stored.first?.authConfiguration.credentialStored, false)
        XCTAssertEqual(stored.first?.authConfigured, false)
    }

    // MARK: restore-on-launch (the P0-4 acceptance)

    func testRestoreRebuildsRegistryIncludingNeverConnectedGateways() async throws {
        // Simulate a PRIOR session's store: one record, never connected.
        let records = TestRecordStore()
        try await records.saveGatewayRecord(StoredGatewayRecord(
            id: gatewayID.rawValue,
            displayName: "Lab Node",
            endpoint: endpoint.absoluteString,
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: true),
            authConfigured: true
        ))
        let credentials = TestCredentialStore()
        try await credentials.saveCredential(
            GatewayCredential(rawValue: "user:fake-low-entropy-pw"),
            for: gatewayID
        )

        // Fresh service (relaunch) over the SAME store + Keychain.
        let (service, _, _) = await makeService(records: records, credentials: credentials)
        let restored = try await service.restorePersistedGateways()

        XCTAssertEqual(restored.map(\.id), [gatewayID], "restore must re-register the stored gateway")
        let all = await service.allGateways()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.displayName, "Lab Node")
        XCTAssertEqual(all.first?.endpoint, endpoint)
        XCTAssertEqual(all.first?.connectionState, .disconnected, "restored gateways are marked disconnected")
        XCTAssertEqual(all.first?.authConfiguration.strategy, .usernamePassword)
        let hasCred = await service.hasCredential(for: gatewayID)
        XCTAssertTrue(hasCred, "restored gateway still has its Keychain credential")
    }

    func testRestoreIsIdempotentAndNeverDuplicates() async throws {
        let records = TestRecordStore()
        try await records.saveGatewayRecord(StoredGatewayRecord(
            id: gatewayID.rawValue,
            displayName: "Lab Node",
            endpoint: endpoint.absoluteString
        ))
        let (service, _, _) = await makeService(records: records)

        _ = try await service.restorePersistedGateways()
        _ = try await service.restorePersistedGateways()

        let all = await service.allGateways()
        XCTAssertEqual(all.count, 1, "restore must not duplicate entries on re-run")
    }

    // MARK: no record store wired (simulator / scripted fleet) — unchanged

    func testServiceWithoutRecordStoreStillRegisters() async throws {
        let service = GatewayRegistryService(
            credentials: TestCredentialStore(),
            connectionFactory: { gateway, _ in
                StubOfflineConnection(gatewayID: gateway.id)
            }
        )
        let gateway = try await service.addGateway(GatewayRegistration(displayName: "MacBook", endpoint: endpoint))
        XCTAssertEqual(gateway.id, gatewayID, "nil record store must not change registry behavior")
    }
}
