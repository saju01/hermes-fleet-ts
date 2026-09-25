import XCTest
import FleetCore
import FleetNetworking
import FleetUI
@testable import HermesFleetApp

final class EmbeddedCompositionTests: XCTestCase {
    func testProductionHTTPSelectsEmbeddedWithoutChangingSystemDefault() {
        var gateway = FleetGateway(id: GatewayID(rawValue: "fixture"), displayName: "Fixture", endpoint: URL(string: "https://host.example.ts.net"))
        XCTAssertTrue(FleetServiceGraph.makeGatewayHTTPSession(gateway: gateway, pinStore: nil) is URLSession)
        gateway.transport = .embeddedTailscale
        XCTAssertTrue(FleetServiceGraph.makeGatewayHTTPSession(gateway: gateway, pinStore: nil) is RoutedGatewayHTTPClient)
    }
}
