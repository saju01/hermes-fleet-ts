import Foundation

/// Input for registering a new gateway (spec §15.2 "add gateway").
///
/// The credential itself is NOT part of registration — it is stored
/// separately through `CredentialStoring` so a secret never transits through
/// the registry model. `authConfiguration` records the strategy + whether a
/// credential exists; the secret stays in Keychain only.
public struct GatewayRegistration: Sendable, Equatable {
    /// Optional explicit identity. When `nil`, the service derives a stable
    /// ID from the endpoint (spec §12: a gateway always has an ID).
    public var id: GatewayID?
    /// User-facing display name (presentation-only; never routing).
    public var displayName: String
    /// Base `http(s)://` endpoint of the gateway.
    public var endpoint: URL
    public var transport: GatewayTransport
    /// Non-secret authentication configuration for this gateway.
    public var authConfiguration: GatewayAuthConfiguration

    public init(
        id: GatewayID? = nil,
        displayName: String,
        endpoint: URL,
        authConfiguration: GatewayAuthConfiguration = .none,
        transport: GatewayTransport = .system
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.transport = transport
        self.authConfiguration = authConfiguration
    }
}
