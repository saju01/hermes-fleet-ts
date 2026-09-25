import Foundation
import XCTest
import FleetCore
@testable import FleetNetworking

final class EmbeddedRoutingTests: XCTestCase {
    func testMissingProxyConfigurationIsRejectedBeforeAnyTaskIsCreated() async throws {
        let endpoint = URL(string: "https://host.example.ts.net")!
        let route = GatewaySessionRoute(endpoint: endpoint) {
            GatewaySessionConfiguration(configuration: .ephemeral, lifetime: GatewaySessionLifetime())
        }
        do { _ = try await route.configuration(for: endpoint); XCTFail("Empty proxy would send credentials directly") }
        catch { XCTAssertTrue(error is EmbeddedTailnetError) }
    }
    func testTicketClientUsesSelectedRouteInsteadOfSharedSession() async throws {
        let endpoint = URL(string: "https://host.example.ts.net")!
        let route = GatewaySessionRoute(endpoint: endpoint) { throw EmbeddedTailnetError.notRunning }
        let client = WSTicketClient(baseURL: endpoint, sessionToken: "SYNTHETIC", urlSession: RoutedGatewayHTTPClient(route: route))
        do { _ = try await client.mintTicket(); XCTFail("No direct ticket mint") }
        catch { XCTAssertTrue(error is EmbeddedTailnetError) }
    }
    func testUnavailableNodeFailsHTTPAndBothSocketPathsWithoutDirectFallback() async throws {
        let endpoint = URL(string: "https://host.example.ts.net")!
        let route = GatewaySessionRoute(endpoint: endpoint) { throw EmbeddedTailnetError.notRunning }
        let http = RoutedGatewayHTTPClient(route: route)
        do {
            _ = try await http.data(for: URLRequest(url: endpoint.appendingPathComponent("auth/password-login")))
            XCTFail("Must fail closed")
        } catch { XCTAssertTrue(error is EmbeddedTailnetError) }
        let factory = RoutedWebSocketSessionFactory(route: route)
        for path in ["/ws", "/api/plugins/kanban/events/ws"] {
            let socket = factory.makeSession(url: URL(string: "wss://host.example.ts.net\(path)")!)
            do { try await socket.open(); XCTFail("Must fail closed") }
            catch { XCTAssertTrue(error is EmbeddedTailnetError) }
        }
    }
}
