import Foundation

/// The gateway-registry management seam (spec §15.2 Gateways, §12 model).
///
/// Lives in FleetCore so the UI depends on this protocol — never on the
/// concrete `GatewayRegistryService` in FleetNetworking (mirrors the M0 seam
/// pattern: `HermesTransport`, `RosterProviding`,
/// `GatewayConnectivityProviding`). Operations:
/// - add / edit / remove gateways (§31 Gateway "register one stock Hermes
///   backend");
/// - store / clear credentials (Keychain via `CredentialStoring`);
/// - test connection (reachable/unreachable probe, §31);
/// - capability surface (§12).
///
/// Fail closed: lookup returns `nil` for unknown IDs; remove/update of an
/// unknown gateway throws `.notFound`; add with a duplicate ID throws
/// `.duplicate`.
public protocol GatewayRegistryManaging: Sendable {
    /// All registered gateways in stable ID order.
    func allGateways() async -> [FleetGateway]

    /// The registered gateway for an ID, or `nil` (fail closed).
    func gateway(for id: GatewayID) async -> FleetGateway?

    /// Register a new gateway. Throws `.duplicate`, `.invalidEndpoint`, or
    /// `.emptyDisplayName` on invalid input.
    func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway

    /// Apply a partial edit. Throws `.notFound` when the gateway is absent.
    func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway

    /// Remove a gateway (and any stored credential for it).
    func removeGateway(_ id: GatewayID) async throws

    /// Roll back an owned new registration without deleting pre-existing TLS trust.
    func removeGatewayPreservingTrust(_ id: GatewayID) async throws

    /// Store a credential for a gateway (Keychain-safe; never logged).
    func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws

    /// Delete the stored credential for a gateway. Missing credential is a
    /// no-op; missing gateway throws `.notFound`.
    func clearCredential(for id: GatewayID) async throws

    /// Whether a credential is currently stored for a gateway.
    func hasCredential(for id: GatewayID) async -> Bool

    /// Probe reachability + adopt the capability surface. Never crashes on
    /// disconnect (spec §31). Classified status always returned (a failed
    /// probe is `.offline` / `.authenticationRequired` / etc., not a thrown
    /// error — unless the gateway is absent).
    func testConnection(to id: GatewayID) async throws -> GatewayTestResult

    /// P0-4: rebuild the in-memory registry from the durable record store on
    /// launch (before seeding). A protocol REQUIREMENT (not just an extension
    /// default) so the concrete production registry's implementation is
    /// dynamically dispatched through the existential; the extension below
    /// provides the no-op default for conformers without persistence.
    func restorePersistedGateways() async throws -> [FleetGateway]
}

extension GatewayRegistryManaging {
    public func removeGatewayPreservingTrust(_ id: GatewayID) async throws {
        throw GatewayRegistryError.pinStoreFailed("registry cannot preserve existing trust")
    }
    /// P0-4 default: no persistence wired (scripted fleet, test doubles) —
    /// restore nothing. Overridden by `GatewayRegistryService` when a
    /// `GatewayRecordStoring` is injected.
    public func restorePersistedGateways() async throws -> [FleetGateway] { [] }
}

/// Errors surfaced by a gateway registry manager. None carry secrets.
public enum GatewayRegistryError: Error, Sendable, Equatable, LocalizedError {
    /// The gateway ID is not registered (fail closed).
    case notFound(GatewayID)
    /// A gateway with this ID is already registered.
    case duplicate(GatewayID)
    /// The registration endpoint is missing or not an http(s) URL.
    case invalidEndpoint
    /// The display name is empty after trimming.
    case emptyDisplayName
    /// The credential-store operation failed (detail is non-secret).
    case credentialStoreFailed(String)
    /// The registration supplied a gateway ID that is not a safe routing key
    /// (path traversal, `#`, separators) — fail closed (M9).
    case invalidGatewayID(String)
    /// The durable gateway-record store operation failed (P0-4; detail is
    /// non-secret).
    case recordStoreFailed(String)
    /// The TLS pin-store operation failed (T3; detail is non-secret — pins
    /// are public key material anyway).
    case pinStoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "gateway not found: \(id.rawValue)"
        case .duplicate(let id): return "gateway already registered: \(id.rawValue)"
        case .invalidEndpoint: return "gateway endpoint must be an http(s) URL"
        case .emptyDisplayName: return "gateway display name cannot be empty"
        case .credentialStoreFailed(let detail): return "credential store failed: \(detail)"
        case .invalidGatewayID(let detail): return "invalid gateway ID: \(detail)"
        case .recordStoreFailed(let detail): return "gateway record store failed: \(detail)"
        case .pinStoreFailed(let detail): return "TLS pin store failed: \(detail)"
        }
    }
}
