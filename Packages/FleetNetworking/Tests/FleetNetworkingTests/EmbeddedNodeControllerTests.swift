import XCTest
import FleetCore
@testable import FleetNetworking

final class EmbeddedNodeControllerTests: XCTestCase {
    func testSuspensionResumesOnlyPreviouslyStartedNode() async throws {
        let driver = Driver()
        let manager = EmbeddedNodeController(driver: driver)
        try await manager.resume()
        let untouched = await driver.starts
        XCTAssertEqual(untouched, 0)
        try await manager.start()
        try await manager.suspend()
        try await manager.resume()
        let restarted = await driver.starts
        XCTAssertEqual(restarted, 2)
        try await manager.stop()
        try await manager.suspend()
        try await manager.resume()
        let stopped = await driver.starts
        XCTAssertEqual(stopped, 2)
    }
    actor Driver: EmbeddedNodeDriving {
        var pauseStop = false
        var stopGate: CheckedContinuation<Void, Never>?
        var logouts = 0
        func pauseNextStop() { pauseStop = true }
        func waitForStop() async { while stopGate == nil { await Task.yield() } }
        func releaseStop() { stopGate?.resume(); stopGate = nil; pauseStop = false }
        var failConfiguration = false
        func failNextConfiguration() { failConfiguration = true }
        var starts = 0
        var stops = 0
        func start() async throws { starts += 1 }
        func login() async throws {}
        func snapshot() async throws -> EmbeddedTailnetSnapshot { .init(state: .running) }
        func configuration() async throws -> URLSessionConfiguration {
            if failConfiguration { throw NSError(domain: "SYNTHETIC-SDK-PRIVATE-DETAIL", code: 1) }
            return .ephemeral
        }
        func stop(logout: Bool) async throws {
            stops += 1
            if logout { logouts += 1 }
            if pauseStop && !logout { await withCheckedContinuation { stopGate = $0 } }
        }
    }
    func testStartIsIdempotentAndStopRevokesExistingSessionLeases() async throws {
        let driver = Driver()
        let manager = EmbeddedNodeController(driver: driver)
        try await manager.start()
        try await manager.start()
        let starts = await driver.starts
        XCTAssertEqual(starts, 1)
        let lease = try await manager.configuration()
        try await manager.stop()
        XCTAssertThrowsError(try lease.lifetime.register(URLSession(configuration: .ephemeral)))
        do { _ = try await manager.configuration(); XCTFail("Stopped nodes must never route") } catch {}
        try await manager.stop()
        let stops = await driver.stops
        XCTAssertEqual(stops, 1)
    }

    func testSDKErrorsAreNotForwardedToGatewayDiagnostics() async throws {
        let driver = Driver()
        let manager = EmbeddedNodeController(driver: driver)
        try await manager.start()
        await driver.failNextConfiguration()
        do { _ = try await manager.configuration(); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error is EmbeddedTailnetError, "Raw SDK error must not escape") }
    }

    func testLogoutDuringSuspensionStillRevokesLogin() async throws {
        let driver = Driver()
        let manager = EmbeddedNodeController(driver: driver)
        try await manager.start()
        await driver.pauseNextStop()
        let suspension = Task { try await manager.suspend() }
        await driver.waitForStop()
        let logout = Task { try await manager.logout() }
        // Let the actor accept logout while shutdown is deliberately blocked.
        try await Task.sleep(for: .milliseconds(30))
        await driver.releaseStop()
        try await suspension.value
        try await logout.value
        let count = await driver.logouts
        XCTAssertEqual(count, 1, "Suspension must not swallow an explicit logout")
    }
}
