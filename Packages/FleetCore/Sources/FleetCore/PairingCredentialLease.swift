import Foundation

/// Attempt-owned credential material. Never durable and never printable.
/// A successful commit switches readers to the ordinary credential store;
/// cancellation permanently revokes access, including that fallback.
public actor PairingCredentialLease: CustomStringConvertible, CustomDebugStringConvertible {
    private enum State { case pending, committed, revoked }
    private let gatewayID: GatewayID
    private var credential: GatewayCredential?
    private var state: State = .pending

    public init(gatewayID: GatewayID, credential: GatewayCredential) {
        self.gatewayID = gatewayID
        self.credential = credential
    }
    public nonisolated var description: String { "PairingCredentialLease(<redacted>)" }
    public nonisolated var debugDescription: String { description }

    public func load(for id: GatewayID, persistentStore: any CredentialStoring) async throws -> GatewayCredential? {
        guard id == gatewayID else { return nil }
        switch state {
        case .pending: return credential
        case .revoked: return nil
        case .committed:
            let stored = try await persistentStore.loadCredential(for: id)
            guard state == .committed else { return nil }
            return stored
        }
    }
    public func checkUsable() throws {
        guard state != .revoked else { throw CancellationError() }
    }
    public func commit() throws {
        guard state == .pending else { throw CancellationError() }
        credential = nil
        state = .committed
    }
    public func revoke() {
        credential = nil
        state = .revoked
    }
}

/// Read-only adapter for the unchanged native GatewayAuthenticator.
public struct PairingCredentialStore: CredentialStoring {
    private let lease: PairingCredentialLease
    private let persistentStore: any CredentialStoring
    public init(lease: PairingCredentialLease, persistentStore: any CredentialStoring) {
        self.lease = lease
        self.persistentStore = persistentStore
    }
    public func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
        try await lease.load(for: gatewayID, persistentStore: persistentStore)
    }
    public func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
        throw CredentialStoreError.storeUnavailable("pairing credential view is read-only")
    }
    public func deleteCredential(for gatewayID: GatewayID) async throws {
        throw CredentialStoreError.storeUnavailable("pairing credential view is read-only")
    }
}
