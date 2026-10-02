import XCTest

/// F3 — first-run onboarding UI regression suite (deterministic, CI-safe).
///
/// Drives the DEBUG simulator build with `HERMES_FLEET_ZERO_GATEWAYS=1`,
/// which suppresses the scripted seed fleet so the app launches with an
/// EMPTY registry. Under the first-run hydration gate the app presents the
/// setup experience AT THE ROOT — before any tab UI. Proves: onboarding is
/// the first meaningful surface; the copy button confirms visibly; the
/// prompt preview renders the Fleet TS private-pairing mission; and the already-have-details hand-off routes into the REAL
/// Add-Gateway form (URL/username/password entry).
@MainActor
final class F3OnboardingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchEmptyFleet() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        return app
    }

    func testFreshInstallLandsOnOnboardingAsRootSurface() throws {
        let app = launchEmptyFleet()

        // The first-run setup experience is the ROOT surface — no tab bar
        // before the first gateway is registered.
        let copy = app.buttons["fleet.onboarding.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15),
                      "a fresh zero-gateway install must land on the setup experience")
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                      "no tab bar before the first gateway is registered")

        // The universal copy is present: connect your first Hermes server.
        XCTAssertTrue(app.staticTexts["Connect your first Hermes server"].exists
                      || app.descendants(matching: .any)
                          .matching(identifier: "fleet.onboarding.headline").firstMatch.exists,
                      "the setup headline renders")

        attachScreenshot(of: app, name: "f3-onboarding-root")
    }

    func testCopyFlowGuidesPrivatePairingAndPreviewIsFleetTS() throws {
        let app = launchEmptyFleet()

        let copy = app.buttons["fleet.onboarding.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15))
        copy.tap()

        // One tap copies — visible confirmation appears.
        let confirmation = app.staticTexts["Copied — open Hermes on Mac/private portal"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10),
                      "copy must show a visible confirmation")

        // The prompt preview renders the full versioned text (review path).
        let toggle = app.buttons["fleet.onboarding.toggle-prompt"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["The prompt you'll send"].waitForExistence(timeout: 10),
                      "prompt preview must open")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.onboarding.prompt-text").firstMatch.exists,
            "full prompt text must render"
        )

        // Product-specific transport and pairing rules must be visible on-device.
        // Do not bake in distribution-channel or private-deployment details.
        let promptText = app.descendants(matching: .any)
            .matching(identifier: "fleet.onboarding.prompt-text").firstMatch.label
        for required in ["Hermes Fleet TS", "Fleet-owned embedded Tailscale", "A reusable credential QR is reusable",
                         "existing connected/selected Hermes gateway", "standard login support",
                         "automatically fills Fleet's Authentication section",
                         "waits for real Tailscale readiness", "automatically performs native Hermes login",
                         "no additional auth action or credential entry"] {
            XCTAssertTrue(promptText.contains(required), "Rendered prompt must require \(required)")
        }
        for banned in ["sideload", "Wi-Fi", "TestFlight", "dogfood", "Reply with exactly: the URL"] {
            XCTAssertFalse(promptText.contains(banned),
                           "rendered prompt must not contain environment assumption \"\(banned)\"")
        }

        // Docs link is present.
        XCTAssertTrue(app.buttons["fleet.onboarding.docs"].exists,
                      "docs link must be present")

        attachScreenshot(of: app, name: "f3-onboarding-copy")
    }

    func testGuidanceRequiresPrivateDisplayAndSupportedPairing() throws {
        let app = launchEmptyFleet()
        XCTAssertTrue(app.buttons["fleet.onboarding.copy"].waitForExistence(timeout: 15))
        let instructions = app.descendants(matching: .any)
            .matching(identifier: "fleet.onboarding.instructions").firstMatch
        XCTAssertTrue(instructions.exists)
        XCTAssertTrue(instructions.label.contains("Mac/private portal"))
        XCTAssertTrue(instructions.label.contains("selected gateway"))
        XCTAssertTrue(instructions.label.contains("existing HTTPS endpoint"))
        XCTAssertTrue(instructions.label.contains("existing token or username/password"))
        XCTAssertTrue(instructions.label.contains("After Tailscale authorization, Hermes login is automatic"))
        XCTAssertTrue(instructions.label.contains("Treat the reusable QR like its credential"))
        XCTAssertTrue(instructions.label.contains("no new service or port"))
        XCTAssertFalse(instructions.label.contains("single-use"))
        XCTAssertFalse(instructions.label.contains("values to enter"))
    }

    func testOnboardingHandsOffToAddGatewayForm() throws {
        let app = launchEmptyFleet()

        let enter = app.buttons["fleet.onboarding.enter-values"]
        XCTAssertTrue(enter.waitForExistence(timeout: 15),
                      "onboarding must offer the already-have-details hand-off")
        enter.tap()

        // The hand-off must present the REAL Add-Gateway sheet (same draft +
        // Keychain path as manual entry).
        let endpoint = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 10),
                      "hand-off must present the real Add-Gateway form")
        XCTAssertTrue(app.buttons["fleet.gateways.form.paste.endpoint"].exists ||
                      app.buttons["fleet.gateways.form.paste.username"].exists,
                      "the form's paste affordances must be reachable for the returned values")

        attachScreenshot(of: app, name: "f3-onboarding-to-add-gateway")
    }

    // MARK: - Helpers

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
