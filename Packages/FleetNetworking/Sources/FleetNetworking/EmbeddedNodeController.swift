import Foundation
import FleetCore

public protocol EmbeddedNodeDriving: Actor {
    func start() async throws
    func login() async throws
    func snapshot() async throws -> EmbeddedTailnetSnapshot
    func configuration() async throws -> URLSessionConfiguration
    func stop(logout: Bool) async throws
}

/// Serializes node lifetime changes, and revokes every HTTP/WS lease on stop.
/// No connection can cause interactive login or a silent direct fallback.
public actor EmbeddedNodeController: EmbeddedTailnetManaging {
    private let driver: any EmbeddedNodeDriving
    private var starting: Task<Void, any Error>?
    private var stopping: Task<Void, any Error>?
    private var stoppingToken: UUID?
    private var stoppingLogsOut = false
    private var active = false
    private var wantsRunning = false
    private var generation = UUID()
    private var lifetime = GatewaySessionLifetime()

    public init(driver: any EmbeddedNodeDriving) { self.driver = driver }

    public func start() async throws {
        wantsRunning = true
        if let stopping { try await stopping.value }
        if let starting { try await starting.value; return }
        guard !active else { return }
        let token = UUID()
        generation = token
        lifetime = GatewaySessionLifetime()
        let task = Task { try await driver.start() }
        starting = task
        do {
            try await task.value
            guard generation == token else { throw CancellationError() }
            active = true
            starting = nil
        } catch {
            if generation == token { starting = nil; lifetime.invalidate() }
            throw EmbeddedTailnetError.notRunning
        }
    }

    public func login() async throws {
        try await start()
        do { try await driver.login() }
        catch { throw EmbeddedTailnetError.notRunning }
    }

    public func snapshot() async -> EmbeddedTailnetSnapshot {
        if starting != nil { return .init(state: .starting) }
        guard active, stopping == nil else { return .init(state: .stopped) }
        let token = generation
        do {
            let value = try await driver.snapshot()
            guard active, generation == token else { return .init(state: .stopped) }
            return value
        } catch { return .init(state: .failed) }
    }

    public func configuration() async throws -> GatewaySessionConfiguration {
        guard active, stopping == nil else { throw EmbeddedTailnetError.notRunning }
        let token = generation
        let owner = lifetime
        do {
            guard try await driver.snapshot().state == .running else { throw EmbeddedTailnetError.notRunning }
            let configuration = try await driver.configuration()
            guard active, generation == token else { throw EmbeddedTailnetError.notRunning }
            return GatewaySessionConfiguration(configuration: configuration, lifetime: owner)
        } catch {
            throw EmbeddedTailnetError.notRunning
        }
    }

    public func stop() async throws { wantsRunning = false; try await shutdown(logout: false) }
    public func logout() async throws { wantsRunning = false; try await shutdown(logout: true) }
    public func suspend() async throws { try await shutdown(logout: false) }
    public func resume() async throws {
        guard wantsRunning else { return }
        try await start()
    }

    private func shutdown(logout: Bool) async throws {
        if let pendingStop = stopping {
            let alreadyLoggingOut = stoppingLogsOut
            do { try await pendingStop.value }
            catch {
                if !logout || alreadyLoggingOut { throw EmbeddedTailnetError.notRunning }
            }
            // A plain stop/suspend is not a logout. Queue the stronger action
            // after it rather than falsely reporting that credentials were revoked.
            if !logout || alreadyLoggingOut { return }
        }
        guard active || starting != nil || logout else { return }
        generation = UUID()
        active = false
        lifetime.invalidate()
        let pending = starting
        starting = nil
        let task = Task {
            _ = try? await pending?.value
            if logout { try await driver.start() }
            try await driver.stop(logout: logout)
        }
        stopping = task
        let token = UUID()
        stoppingToken = token
        stoppingLogsOut = logout
        defer {
            if stoppingToken == token { stopping = nil; stoppingToken = nil }
        }
        do { try await task.value }
        catch { throw EmbeddedTailnetError.notRunning }
    }
}
