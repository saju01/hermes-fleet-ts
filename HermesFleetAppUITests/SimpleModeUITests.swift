import XCTest

/// Simple mode (scripted simulator fleet): chat-only root with model +
/// thinking chips, a browser card when browser tools run, the full-screen
/// takeover with Take control / Hand back over the scripted RFB desktop,
/// and the Advanced entry into the existing tab shell.
final class SimpleModeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testSimpleChatBrowserCardTakeoverHandBackAndAdvanced() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_UI_MODE"] = "simple"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        XCTAssertTrue(UITestLaunchSupport.launch(app, ready: el(app, "simple.composer"), timeout: 20),
                      "Simple mode root should render a composer")

        // The scripted fleet seeds three gateways; one (Lab Node) is scripted
        // unreachable. Pick the healthy Workstation via the menu.
        el(app, "simple.menu").tap()
        let workstation = app.buttons["Workstation"].firstMatch
        XCTAssertTrue(workstation.waitForExistence(timeout: 5), "gateway picker lists registered gateways")
        workstation.tap()
        XCTAssertTrue(app.navigationBars["Workstation"].waitForExistence(timeout: 10))

        XCTAssertTrue(el(app, "simple.chip.model").waitForExistence(timeout: 10), "model chip")
        let thinking = el(app, "simple.chip.thinking")
        XCTAssertTrue(thinking.waitForExistence(timeout: 10), "thinking chip")
        thinking.tap()
        let high = el(app, "simple.thinking.high")
        XCTAssertTrue(high.waitForExistence(timeout: 5), "effort levels offered")
        high.tap()
        XCTAssertTrue(el(app, "simple.composer").waitForExistence(timeout: 10))

        let composer = el(app, "simple.composer")
        composer.tap()
        composer.typeText("open the browser please")
        let send = el(app, "simple.send")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(10)
        while !send.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(send.isEnabled, "send enables once the chat is open and text is entered")
        send.tap()

        let card = el(app, "simple.browser.card")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "browser tools render one live browser card")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "simple.browser.card").count, 1,
                       "consecutive browser steps collapse into one card")
        XCTAssertTrue(el(app, "simple.browser.thumbnail").waitForExistence(timeout: 10), "thumbnail polled")

        el(app, "simple.browser.takecontrol").tap()
        XCTAssertTrue(el(app, "simple.takeover").waitForExistence(timeout: 10), "full-screen takeover")
        XCTAssertTrue(el(app, "simple.takeover.frame").waitForExistence(timeout: 15), "RFB frame decoded")
        let handBack = el(app, "simple.takeover.handback")
        XCTAssertTrue(handBack.waitForExistence(timeout: 10), "in control after lease acquire")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "simple-takeover-in-control"
        attachment.lifetime = .keepAlways
        add(attachment)

        handBack.tap()
        XCTAssertTrue(el(app, "simple.takeover.takecontrol").waitForExistence(timeout: 10),
                      "hand back drops to watching")
        el(app, "simple.takeover.done").tap()
        XCTAssertTrue(el(app, "simple.composer").waitForExistence(timeout: 10))

        el(app, "simple.menu").tap()
        let advanced = el(app, "simple.advanced")
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10)
                      || app.buttons["Gateways"].waitForExistence(timeout: 5),
                      "Advanced opens the existing tab shell")
    }
}
