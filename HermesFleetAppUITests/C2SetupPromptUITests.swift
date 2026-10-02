import XCTest
import UIKit

/// C2 — Settings ▸ Agent Setup Prompt door regression suite (deterministic, CI-safe).
///
/// The nav rebuild orphaned the onboarding screen behind the empty-gateways
/// state, so the setup prompt silently vanished for anyone with a configured
/// gateway. These tests assert POSITIVELY (QA discipline) that the door
/// exists on the Settings screen and opens the sheet — with the DEFAULT
/// seeded fleet (a configured gateway), i.e. exactly the state where the old
/// door disappeared. If this row is ever orphaned again, CI fails.
@MainActor
final class C2SetupPromptUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings shows the Agent Setup Prompt row (default scripted fleet —
    /// gateways EXIST, the state where the old door was unreachable).
    func testSettingsShowsSetupPromptRow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)

        let row = app.buttons["fleet.settings.setup-prompt"]
        // FOS-3: the Appearance section (picker + accents) sits above the
        // Agent group — scroll the row into the AX tree if needed.
        if !row.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Settings must expose the Agent Setup Prompt row — the door was orphaned once; never again")
        XCTAssertTrue(app.staticTexts["Set Up Another Server"].exists || row.exists)
        attachScreenshot(of: app, name: "c2-settings-row")
    }

    /// The row opens the sheet: copy button, share affordance, and the
    /// versioned prompt preview are all present and work.
    func testSetupPromptRowOpensSheetWithCopyShareAndPreview() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openSettings(app)

        let row = app.buttons["fleet.settings.setup-prompt"]
        if !row.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if !row.isHittable { app.swipeUp() }
        row.tap()

        // Sheet appears with the copy + share affordances.
        let copy = app.buttons["fleet.setup-prompt.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10),
                      "the setup-prompt sheet must show the Copy button")
        XCTAssertTrue(app.buttons["fleet.setup-prompt.share"].exists,
                      "the setup-prompt sheet must show the Share affordance")
        XCTAssertTrue(app.navigationBars["Set Up Another Server"].waitForExistence(timeout: 5))

        let instructions = app.descendants(matching: .any)
            .matching(identifier: "fleet.setup-prompt.instructions").firstMatch
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

        // Copy confirms visibly.
        copy.tap()
        XCTAssertTrue(app.buttons["fleet.setup-prompt.copy"]
            .waitForExistence(timeout: 5))
        let confirmed = app.staticTexts["Copied — open Hermes on Mac/private portal"].waitForExistence(timeout: 10)
            || app.buttons["fleet.setup-prompt.copy"].label.contains("Copied")
        XCTAssertTrue(confirmed, "copy must show a visible confirmation")

        // Preview renders the canonical Fleet TS prompt text.
        let toggle = app.buttons["fleet.setup-prompt.toggle-prompt"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["The prompt you'll send"].waitForExistence(timeout: 10),
                      "prompt preview must open")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.setup-prompt.prompt-text").firstMatch.exists,
            "the Fleet TS prompt text must render")

        // Close dismisses back to Settings.
        app.buttons["fleet.setup-prompt.close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Close must dismiss the sheet back to Settings")
        attachScreenshot(of: app, name: "c2-setup-prompt-sheet")
    }

    func testOnboardingAndSettingsCopyTheSamePrivatePairingPrompt() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1"
        app.launch()
        let copy = app.buttons["fleet.onboarding.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15))
        UIPasteboard.general.string = "onboarding-copy-not-yet-performed"
        copy.tap()
        // Copy inserts a confirmation row and moves the preview button. Wait
        // for that state before targeting it, rather than tapping its old frame.
        XCTAssertTrue(app.staticTexts["Copied — open Hermes on Mac/private portal"]
            .waitForExistence(timeout: 5))
        app.buttons["fleet.onboarding.toggle-prompt"].tap()
        let firstPreview = app.descendants(matching: .any)
            .matching(identifier: "fleet.onboarding.prompt-text").firstMatch
        XCTAssertTrue(firstPreview.waitForExistence(timeout: 10))
        let canonicalText = firstPreview.label
        XCTAssertTrue(canonicalText.contains("Hermes Fleet TS"))
        XCTAssertTrue(canonicalText.contains("A reusable credential QR is reusable"))
        XCTAssertTrue(canonicalText.contains("automatically fills Fleet's Authentication section"))
        XCTAssertTrue(canonicalText.contains("automatically performs native Hermes login"))
        XCTAssertFalse(canonicalText.contains("short-lived, single-use QR"))
        XCTAssertTrue(canonicalText.contains("remote-UI-only"))

        // Hide the long preview before reaching the existing manual fallback.
        app.buttons["fleet.onboarding.toggle-prompt"].tap()
        let enter = app.buttons["fleet.onboarding.enter-values"]
        for _ in 0..<5 where !enter.isHittable { app.swipeUp() }
        enter.tap()
        assertClipboardEquals(canonicalText, in: app)
        app.buttons["fleet.gateways.form.cancel"].tap()
        app.terminate()

        // A configured fleet exposes the same artifact from Settings.
        app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "0"
        app.launch()
        UITabNavigation.openSettings(app)
        let row = app.buttons["fleet.settings.setup-prompt"]
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let settingsCopy = app.buttons["fleet.setup-prompt.copy"]
        XCTAssertTrue(settingsCopy.waitForExistence(timeout: 10))
        UIPasteboard.general.string = "settings-copy-not-yet-performed"
        settingsCopy.tap()
        XCTAssertTrue(app.staticTexts["Copied — open Hermes on Mac/private portal"]
            .waitForExistence(timeout: 5))
        app.buttons["fleet.setup-prompt.toggle-prompt"].tap()
        let settingsPreview = app.descendants(matching: .any)
            .matching(identifier: "fleet.setup-prompt.prompt-text").firstMatch
        for _ in 0..<5 where !settingsPreview.exists { app.swipeUp() }
        XCTAssertTrue(settingsPreview.waitForExistence(timeout: 10))
        XCTAssertEqual(settingsPreview.label, canonicalText,
                       "Settings and first-run must render the same canonical prompt, not forked prose")
        app.buttons["fleet.setup-prompt.close"].tap()
        app.buttons["fleet.settings.done"].tap()
        UITabNavigation.openGatewaysTab(app)
        app.buttons["fleet.gateways.add"].tap()
        assertClipboardEquals(canonicalText, in: app)
        app.buttons["fleet.gateways.form.cancel"].tap()
    }

    private func assertClipboardEquals(_ expected: String, in app: XCUIApplication) {
        let paste = app.buttons["fleet.gateways.form.paste.endpoint"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        paste.tap()
        // A single-line UITextField exposes each pasted newline as one space.
        // Compare every other byte, rather than weakening this to keyword checks.
        XCTAssertEqual(app.textFields["fleet.gateways.form.endpoint"].value as? String,
                       expected.replacingOccurrences(of: "\n", with: " "),
                       "Copy must deliver the actual canonical prompt, not just animate a confirmation")
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
