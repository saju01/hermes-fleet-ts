import XCTest
import FleetCore
import FleetNetworking
@testable import FleetUI

/// Simple mode composition + UI-mode gate (hosted).
@MainActor
final class SimpleModeCompositionTests: XCTestCase {

    func testProductionConversationSessionCarriesBotDisplayOnTheSameSession() {
        struct NoAuth: AuthenticationProviding {
            func authenticate() async throws -> ConnectionAuthentication { .none }
        }
        let transport = GatewayWebSocketTransport(baseURL: URL(string: "http://127.0.0.1:1")!, authentication: NoAuth())
        let session: any ConversationSessionProviding = GatewayConversationSession(
            gatewayID: GatewayID(rawValue: "gw"), displayName: "gw",
            endpoint: URL(string: "http://127.0.0.1:1"), transport: transport)
        XCTAssertNotNil(session as? BotDisplayCapable, "the display seam rides the conversation transport")
    }

    func testUIModeResolutionOrderAndPinnedModeIsNotPersisted() {
        let suite = "simple-mode-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(FleetUIModeController(defaults: defaults, environment: [:], fallback: .simple).mode, .simple)
        let c = FleetUIModeController(defaults: defaults, environment: [:], fallback: .simple)
        c.setMode(.advanced)
        XCTAssertEqual(FleetUIModeController(defaults: defaults, environment: [:], fallback: .simple).mode, .advanced,
                       "a user choice persists and beats the fallback")

        let pinned = FleetUIModeController(defaults: defaults, environment: ["HERMES_FLEET_UI_MODE": "simple"], fallback: .advanced)
        XCTAssertEqual(pinned.mode, .simple)
        pinned.setMode(.simple)
        XCTAssertEqual(defaults.string(forKey: FleetUIModeController.defaultsKey), "advanced",
                       "a launch-env pin never rewrites the stored choice")
    }

    func testSimpleTranscriptOnlySurfacesBrowserTools() {
        XCTAssertTrue(SimpleTranscript.isBrowserTool("browser_navigate"))
        XCTAssertTrue(SimpleTranscript.isBrowserTool("browser_click"))
        XCTAssertFalse(SimpleTranscript.isBrowserTool("browser_vault_fill"))
        XCTAssertFalse(SimpleTranscript.isBrowserTool("terminal"))
    }

    func testEffortPickIsStickyPerGatewayAndCapabilityGated() {
        let gw = GatewayID(rawValue: "effort-\(UUID().uuidString)")
        defer { UserDefaults.standard.removeObject(forKey: "fleet.effortpick.\(gw.rawValue)") }
        let vm = ConversationToolingViewModel(tooling: UnsupportedConversationTooling(), gatewayID: gw)
        XCTAssertNil(vm.selectedEffort)
        XCTAssertEqual(vm.availableEfforts, ReasoningEffort.allCases, "unknown capabilities offer every level")
        vm.selectEffort(.high)
        XCTAssertEqual(ConversationToolingViewModel(tooling: UnsupportedConversationTooling(), gatewayID: gw).selectedEffort, .high)
        vm.select(ModelChoice(model: "m", provider: "p", providerName: "P", isCurrent: false,
                              supportsReasoning: true, canDisableReasoning: false))
        XCTAssertFalse(vm.availableEfforts.contains(.none))
        vm.select(nil)
        vm.selectEffort(nil)
        XCTAssertNil(ConversationToolingViewModel(tooling: UnsupportedConversationTooling(), gatewayID: gw).selectedEffort)
    }
}
