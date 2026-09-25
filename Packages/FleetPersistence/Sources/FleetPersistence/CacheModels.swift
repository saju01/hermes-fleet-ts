import Foundation
import SwiftData

/// One persisted non-secret transcript message row (synthesis §12: SwiftData
/// caches non-secret session history). Fields mirror `SessionMessage` exactly
/// (role/text/timestamp/rowID/displayKind/reasoning/toolName/toolContext).
///
/// **Structural no-secret invariant:** there is NO token, ticket, credential,
/// password, or key field on this or any cache model — secrets live only in
/// Keychain (`KeychainTokenStore` / `KeychainCredentialStore`).
@Model
public final class CachedMessageRow {
    /// Owning gateway (canonical `GatewayID.rawValue`).
    public var gatewayID: String
    /// The runtime session id these rows belong to.
    public var sessionID: String
    /// Transcript order (0-based chronological).
    public var order: Int
    /// `SessionMessageRole.wireValue` ("user"/"assistant"/"tool"/"system"/"unknown").
    public var role: String
    /// The rendered text of the message.
    public var text: String
    /// Persisted authoring time (Unix seconds), when the gateway stamped it.
    public var timestamp: Double?
    /// Durable row identity for the persisted turn, when present.
    public var rowID: String?
    /// Launch-stable client identity (B1): the UUID minted at SessionMessage
    /// construction when the gateway stamped no row_id. Persisted so a fresh
    /// model container reloads the same message with the same id across app
    /// launches (never re-derived from a randomized hash).
    public var clientID: String?
    /// Display-only classification, preserved verbatim.
    public var displayKind: String?
    /// Assistant reasoning/thinking content, when disclosed.
    public var reasoning: String?
    /// Tool message metadata: the tool's name (tool messages only).
    public var toolName: String?
    /// Tool message context (an 80-char preview of the call), tool only.
    public var toolContext: String?
    /// R10-T2: this row's reactions, JSON-encoded
    /// (`[{"emoji","author","at"?}]`) — nil when none were disclosed. An
    /// additive optional column: legacy rows decode nil via lightweight
    /// migration. Non-secret display metadata.
    public var reactionsData: String?

    public init(
        gatewayID: String,
        sessionID: String,
        order: Int,
        role: String,
        text: String,
        timestamp: Double?,
        rowID: String?,
        displayKind: String?,
        reasoning: String?,
        toolName: String?,
        toolContext: String?,
        reactionsData: String? = nil,
        clientID: String? = nil
    ) {
        self.gatewayID = gatewayID
        self.sessionID = sessionID
        self.order = order
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.rowID = rowID
        self.clientID = clientID
        self.displayKind = displayKind
        self.reasoning = reasoning
        self.toolName = toolName
        self.toolContext = toolContext
        self.reactionsData = reactionsData
    }
}

/// One persisted per-(gateway, session) seq watermark (spec §9: the highest
/// event `seq` this client observed for a session, surviving relaunch so a
/// reconnecting client can request `session.events.since(lastSeen)`).
@Model
public final class CachedWatermarkRow {
    /// Owning gateway (canonical `GatewayID.rawValue`).
    public var gatewayID: String
    /// The runtime session id these events belong to.
    public var sessionID: String
    /// The highest `seq` observed for that session (0 = none observed yet).
    public var lastSeenSeq: Int

    public init(gatewayID: String, sessionID: String, lastSeenSeq: Int) {
        self.gatewayID = gatewayID
        self.sessionID = sessionID
        self.lastSeenSeq = lastSeenSeq
    }
}

/// One persisted last-adopted `replay_epoch` per gateway (spec §9.6 /
/// synthesis §12 "relaunch-resume; stale epoch → reset"). When the fresh
/// `gateway.ready.replay_epoch` differs, the client resets stale seq
/// assumptions and rehydrates.
@Model
public final class CachedReplayEpochRow {
    /// Owning gateway (canonical `GatewayID.rawValue`).
    public var gatewayID: String
    /// The last adopted replay_epoch (`nil` = none adopted yet).
    public var epoch: String?

    public init(gatewayID: String, epoch: String?) {
        self.gatewayID = gatewayID
        self.epoch = epoch
    }
}

/// One persisted per-gateway connection-health snapshot (H2 Connection health
/// dashboard). Mirrors `GatewayHealthStats` exactly — counts, timestamps, and
/// classified reasons only.
///
/// **Structural no-secret invariant:** like every cache model, there is NO
/// token, ticket, credential, password, or key field here — health stats are
/// non-secret by construction (synthesis §12).
@Model
public final class CachedHealthStatsRow {
    /// Owning gateway (canonical `GatewayID.rawValue`).
    public var gatewayID: String
    /// `GatewayStatus.rawValue` of the last known state ("online"/"offline"/…).
    public var currentStateRaw: String
    /// When the accumulator first observed this gateway.
    public var firstObservedAt: Date
    /// Wall-clock timestamp of the most recent state transition.
    public var lastTransitionAt: Date
    /// Accumulated connected time (milliseconds).
    public var connectedMilliseconds: Int64
    /// Accumulated disconnected time (milliseconds).
    public var disconnectedMilliseconds: Int64
    /// Number of re-establishments after the first connect.
    public var reconnectCount: Int
    /// Human-readable reason the connection last ended (non-secret).
    public var lastDisconnectReason: String?
    /// When that disconnect happened.
    public var lastDisconnectAt: Date?
    /// Most recent heartbeat ping RTT (milliseconds).
    public var lastPingRTTMilliseconds: Double?
    /// Running average heartbeat ping RTT (milliseconds).
    public var averagePingRTTMilliseconds: Double?
    /// Number of ping RTT samples observed.
    public var pingSampleCount: Int

    public init(
        gatewayID: String,
        currentStateRaw: String,
        firstObservedAt: Date,
        lastTransitionAt: Date,
        connectedMilliseconds: Int64,
        disconnectedMilliseconds: Int64,
        reconnectCount: Int,
        lastDisconnectReason: String?,
        lastDisconnectAt: Date?,
        lastPingRTTMilliseconds: Double?,
        averagePingRTTMilliseconds: Double?,
        pingSampleCount: Int
    ) {
        self.gatewayID = gatewayID
        self.currentStateRaw = currentStateRaw
        self.firstObservedAt = firstObservedAt
        self.lastTransitionAt = lastTransitionAt
        self.connectedMilliseconds = connectedMilliseconds
        self.disconnectedMilliseconds = disconnectedMilliseconds
        self.reconnectCount = reconnectCount
        self.lastDisconnectReason = lastDisconnectReason
        self.lastDisconnectAt = lastDisconnectAt
        self.lastPingRTTMilliseconds = lastPingRTTMilliseconds
        self.averagePingRTTMilliseconds = averagePingRTTMilliseconds
        self.pingSampleCount = pingSampleCount
    }
}

/// One persisted gateway-record row (P0-4, t_e32529e8): the durable, non-secret
/// registration of a user-added gateway so the fleet roster survives app
/// close / relaunch. Fields mirror `StoredGatewayRecord` exactly — the record
/// is written IMMEDIATELY on Add regardless of connection state.
///
/// **Structural no-secret invariant:** like every cache model, there is NO
/// token, ticket, credential, password, or key field here — the secret lives
/// only in Keychain (`KeychainCredentialStore`); this row stores only the
/// auth STRATEGY name + credential-stored flag (synthesis §12).
@Model
public final class CachedGatewayRow {
    /// Canonical gateway identity (`GatewayID.rawValue`) — primary key.
    public var gatewayID: String
    /// User-facing display name (presentation-only).
    public var displayName: String
    /// Base `http(s)://` endpoint origin.
    public var endpoint: String
    /// Non-secret auth STRATEGY raw value ("none"/"sessionToken"/…) — never
    /// secret material.
    public var authStrategyRaw: String
    // Optional for lightweight migration of existing stores. Nil means system.
    public var transportRaw: String?
    /// Whether a credential was stored (Keychain) at persist time.
    public var credentialStored: Bool
    /// Whether auth was configured at persist time (informational; re-derived
    /// from Keychain on restore).
    public var authConfigured: Bool

    public init(
        gatewayID: String,
        displayName: String,
        endpoint: String,
        authStrategyRaw: String,
        transportRaw: String? = nil,
        credentialStored: Bool,
        authConfigured: Bool
    ) {
        self.gatewayID = gatewayID
        self.displayName = displayName
        self.endpoint = endpoint
        self.authStrategyRaw = authStrategyRaw
        self.transportRaw = transportRaw
        self.credentialStored = credentialStored
        self.authConfigured = authConfigured
    }
}
