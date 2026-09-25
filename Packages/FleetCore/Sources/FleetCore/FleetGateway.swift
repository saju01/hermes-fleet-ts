import Foundation

/// A fleet gateway (Hermes node) as known to the client.
///
/// M0 shipped the minimal identity shape (id + display name). M2 expands it to
/// the registry entry fields the fleet model requires (synthesis §6): ID,
/// display name, endpoint, connection state, capabilities, server identity,
/// replay_epoch. Server state is authoritative over any local cache.
///
/// The M0 memberwise call site `FleetGateway(id:displayName:)` remains valid —
/// all new fields default.
public struct FleetGateway: Identifiable, Hashable, Sendable {
    /// Globally unique gateway identifier — the identity half of every route.
    public let id: GatewayID
    /// User-facing name. Presentation-only; never used for routing.
    public var displayName: String
    /// Base `http(s)://` endpoint used to mint WS tickets and build socket URLs.
    public var endpoint: URL?
    public var transport: GatewayTransport
    /// Last known connection state (derived from the transport seam).
    public var connectionState: TransportState
    /// Capability flags advertised by the gateway (e.g. heartbeat, change_events).
    public var capabilities: Set<String>
    /// Stable server identity string when the gateway reports one.
    public var serverIdentity: String?
    /// Replay epoch adopted from `gateway.ready` (drives rehydration, P4).
    public var replayEpoch: String?
    /// True once the gateway has been authenticated (token/ticket stored) —
    /// informational only; never a secret.
    public var authConfigured: Bool
    /// Non-secret authentication configuration (strategy + credential-stored
    /// flag). The secret itself lives in Keychain (spec §12, §16).
    public var authConfiguration: GatewayAuthConfiguration

    public init(
        id: GatewayID,
        displayName: String,
        endpoint: URL? = nil,
        connectionState: TransportState = .disconnected,
        capabilities: Set<String> = [],
        serverIdentity: String? = nil,
        replayEpoch: String? = nil,
        authConfigured: Bool = false,
        authConfiguration: GatewayAuthConfiguration = .none,
        transport: GatewayTransport = .system
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.transport = transport
        self.connectionState = connectionState
        self.capabilities = capabilities
        self.serverIdentity = serverIdentity
        self.replayEpoch = replayEpoch
        self.authConfigured = authConfigured
        self.authConfiguration = authConfiguration
    }
}
