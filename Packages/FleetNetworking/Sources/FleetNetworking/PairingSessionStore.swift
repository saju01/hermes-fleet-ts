import Foundation
import FleetCore

/// A pairing attempt must authenticate its QR, never borrow another attempt's
/// cached cookie. The login is structured (no detached/in-flight task), so its
/// HTTP request inherits cancellation. Successful reconnects reuse this cookie.
public actor PairingSessionStore: GatewayAuthenticator.GatewaySessionLeasing {
    private let credentialLease: PairingCredentialLease
    private var sessions: [GatewayID: SessionCookie] = [:]
    private var generation = UUID()

    public init(credentialLease: PairingCredentialLease) {
        self.credentialLease = credentialLease
    }
    public func lease(gatewayID: GatewayID, login: @escaping @Sendable () async throws -> SessionCookie) async throws -> SessionCookie {
        try Task.checkCancellation()
        try await credentialLease.checkUsable()
        if let cookie = sessions[gatewayID] { return cookie }
        let generation = self.generation
        let cookie = try await login()
        try Task.checkCancellation()
        try await credentialLease.checkUsable()
        guard generation == self.generation else { throw CancellationError() }
        sessions[gatewayID] = cookie
        return cookie
    }
    public func invalidate(gatewayID: GatewayID) {
        generation = UUID()
        sessions[gatewayID] = nil
    }
}
