import XCTest
import FleetCore
import TailscaleKit
@testable import HermesFleetApp

final class EmbeddedTailscaleAdapterTests: XCTestCase {
    func testGoLoggingIsExplicitlyDiscardedNotLeftAtSDKDefault() {
        XCTAssertEqual(TailscalePrivateLogger().logFileHandle, -1)
    }
    func testEnrollmentConsumerAcceptsOnlyOfficialHTTPSURLAndClearsOnRunning() async throws {
        let consumer = TailscaleIPNConsumer()
        let invalid = try JSONDecoder().decode(Ipn.Notify.self, from: Data(#"{"State":2,"BrowseToURL":"https://login.tailscale.com.evil.invalid/a/fixture"}"#.utf8))
        await consumer.notify(invalid)
        let rejected = await consumer.value()
        XCTAssertNil(rejected.enrollmentURL)
        let valid = try JSONDecoder().decode(Ipn.Notify.self, from: Data(#"{"State":2,"BrowseToURL":"https://login.tailscale.com/a/SYNTHETIC"}"#.utf8))
        await consumer.notify(valid)
        let accepted = await consumer.value()
        XCTAssertEqual(accepted.state, .needsLogin)
        XCTAssertEqual(accepted.enrollmentURL?.host, "login.tailscale.com")
        let running = try JSONDecoder().decode(Ipn.Notify.self, from: Data(#"{"State":6}"#.utf8))
        await consumer.notify(running)
        let final = await consumer.value()
        XCTAssertEqual(final.state, .running)
        XCTAssertNil(final.enrollmentURL)
    }
}
