import XCTest
import FleetCore
import FleetUI

@MainActor
final class EmbeddedTailnetUITests: XCTestCase {
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
