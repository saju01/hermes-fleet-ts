import Foundation

/// Non-secret durable record of a registered gateway (P0-4, t_e32529e8).
///
/// Persisted IMMEDIATELY when a gateway is added (regardless of connection
/// state) so the fleet roster survives app close / relaunch. Mirrors the
/// registry-entry fields the user entered — id, display name, endpoint, and
/// the NON-SECRET auth configuration (strategy + whether a credential is
/// stored). The credential itself lives exclusively in Keychain
/// (`CredentialStoring`), never here (spec §12, §16 — same structural
/// no-secret invariant as `CacheStoring`).
public struct StoredGatewayRecord: Codable, Hashable, Sendable, Equatable {
    /// Canonical gateway identity (`GatewayID.rawValue`).
    public var id: String
    /// User-facing display name (presentation-only).
    public var displayName: String
    /// Base `http(s)://` endpoint origin.
    public var endpoint: String
    /// Non-secret authentication configuration (strategy + credential-stored
    /// flag). No secret material — Keychain only.
    public var authConfiguration: GatewayAuthConfiguration
    /// Whether auth was configured for this gateway at persist time
    /// (informational; the flag is re-derived from Keychain on restore).
    public var authConfigured: Bool
    public var transport: GatewayTransport

    public init(
        id: String,
        displayName: String,
        endpoint: String,
        authConfiguration: GatewayAuthConfiguration = .none,
        authConfigured: Bool = false,
        transport: GatewayTransport = .system
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.authConfiguration = authConfiguration
        self.authConfigured = authConfigured
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, endpoint, authConfiguration, authConfigured, transport
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        authConfiguration = try values.decode(GatewayAuthConfiguration.self, forKey: .authConfiguration)
        authConfigured = try values.decode(Bool.self, forKey: .authConfigured)
        // Unknown explicit modes fail decoding rather than silently becoming direct.
        transport = try values.decodeIfPresent(GatewayTransport.self, forKey: .transport) ?? .system
    }
}

/// Durable non-secret gateway-record persistence seam (P0-4).
///
/// Lives in FleetCore so the registry service and the composition root depend
/// on the protocol — never on the concrete SwiftData implementation in
/// FleetPersistence (mirrors the `CredentialStoring` / `CacheStoring` seam
/// pattern). Concrete store: `SwiftDataCacheStore` (it already owns the app's
/// non-secret persistence file); tests use in-memory containers.
///
/// Semantics:
/// - `saveGatewayRecord` is an UPSERT keyed by gateway id (replace, not
///   duplicate).
/// - `deleteGatewayRecord` removes one record; missing id is a no-op.
/// - `loadGatewayRecords` returns all records (empty array when none).
public protocol GatewayRecordStoring: Sendable {
    /// Upsert one gateway record (keyed by `record.id`).
    func saveGatewayRecord(_ record: StoredGatewayRecord) async throws
    /// Remove the record for a gateway id. Missing id is a no-op.
    func deleteGatewayRecord(id: GatewayID) async throws
    /// All stored gateway records (empty when the store holds none).
    func loadGatewayRecords() async throws -> [StoredGatewayRecord]
}
