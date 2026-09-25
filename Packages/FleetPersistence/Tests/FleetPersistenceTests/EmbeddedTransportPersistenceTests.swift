import XCTest
import FleetCore
@testable import FleetPersistence

final class EmbeddedTransportPersistenceTests: XCTestCase {
    func testEmbeddedTransportSurvivesDurableStore() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let record = StoredGatewayRecord(id: "fixture", displayName: "Fixture", endpoint: "https://host.example.ts.net", transport: .embeddedTailscale)
        try await store.saveGatewayRecord(record)
        let loaded = try await store.loadGatewayRecords()
        XCTAssertEqual(loaded.first?.transport, .embeddedTailscale)
    }
}
