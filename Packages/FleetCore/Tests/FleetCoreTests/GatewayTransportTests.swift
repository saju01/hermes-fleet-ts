import Foundation
import XCTest
@testable import FleetCore

final class GatewayTransportTests: XCTestCase {
    func testStoredTransportSurvivesRoundTripAndLegacyRecordDefaultsToSystem() throws {
        let legacy = #"{"id":"fixture","displayName":"Fixture","endpoint":"https://host.example.ts.net","authConfiguration":{"strategy":"none","credentialStored":false},"authConfigured":false}"#.data(using: .utf8)!
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        json["transport"] = "embeddedTailscale"
        let record = try JSONDecoder().decode(StoredGatewayRecord.self, from: JSONSerialization.data(withJSONObject: json))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(encoded["transport"] as? String, "embeddedTailscale")
        let old = try JSONDecoder().decode(StoredGatewayRecord.self, from: legacy)
        let oldEncoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertEqual(oldEncoded["transport"] as? String, "system")
    }
}
