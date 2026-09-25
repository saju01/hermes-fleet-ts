import Foundation
import FleetCore

/// Builds a single-gateway connection for a registered gateway, so the
/// registry service can probe reachability + capability surface without
/// depending on transport construction itself. Injected at the composition
/// root (app target) — keeps `GatewayRegistryService` free of concrete
/// transport wiring and lets tests inject in-process-server connections.
public typealias GatewayConnectionFactory = @Sendable (
    _ gateway: FleetGateway,
    _ credential: GatewayCredential?
) -> any GatewayConnectivityProviding

/// Concrete `GatewayRegistryManaging` — the M7 Gateway Registry service.
///
/// Owns the in-memory `GatewayRegistry` (M2), stores credentials through the
/// injected `CredentialStoring` seam (Keychain in production, in-memory in
/// tests), and probes connectivity through the injected `GatewayConnectionFactory`.
///
/// Responsibilities (spec §15.2 Gateways / §31 Gateway / §12 model):
/// - add / edit / remove gateways;
/// - authenticate (store/clear credentials — Keychain-safe, never logged);
/// - test connection (reachable/unreachable probe + capability surface);
/// - lookup fails closed (nil / `.notFound` for unknown IDs).
///
/// No live Hermes gateway is required to construct this service; tests drive
/// it with in-process fixture servers (consistent with M1–M6).
public actor GatewayRegistryService: GatewayRegistryManaging {
    private var registry: GatewayRegistry
    private let credentials: any CredentialStoring
    private let connectionFactory: GatewayConnectionFactory
    /// P0-4: durable non-secret gateway-record store. Every durable mutation
    /// writes through immediately; `nil` (scripted fleet / tests) keeps the
    /// registry purely in-memory, exactly as before.
    private let recordStore: (any GatewayRecordStoring)?
    /// T3: per-gateway TLS pin store (TOFU SPKI pinning). `nil` keeps the
    /// registry pin-unaware (scripted fleet / legacy tests).
    private let pinStore: (any TLSPinStoring)?

    public init(
        registry: GatewayRegistry = GatewayRegistry(),
        credentials: any CredentialStoring,
        connectionFactory: @escaping GatewayConnectionFactory,
        recordStore: (any GatewayRecordStoring)? = nil,
        pinStore: (any TLSPinStoring)? = nil
    ) {
        self.registry = registry
        self.credentials = credentials
        self.connectionFactory = connectionFactory
        self.recordStore = recordStore
        self.pinStore = pinStore
    }

    // MARK: GatewayRegistryManaging

    public func allGateways() async -> [FleetGateway] {
        registry.allGateways
    }

    public func gateway(for id: GatewayID) async -> FleetGateway? {
        registry.gateway(for: id)
    }

    public func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
        // Fail closed on invalid input before mutating anything.
        let displayName = registration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw GatewayRegistryError.emptyDisplayName
        }
        // P1-6: treat the endpoint as an ORIGIN — reject user-info, strip
        // query/fragment at the registry boundary before anything is stored,
        // displayed, or logged.
        let endpoint = try GatewayEndpoint.normalizedOrigin(from: registration.endpoint)
        if registration.transport == .embeddedTailscale {
            try EmbeddedTailnetPolicy.validateEndpoint(endpoint)
        }
        let id = registration.id ?? GatewayID(endpoint: endpoint)
        // M9 fail-closed guard: an unsafe gateway ID (path traversal, `#`,
        // separators) is rejected before registration — it must never become
        // the identity half of a route or a Keychain key.
        guard id.isRoutingSafe else {
            throw GatewayRegistryError.invalidGatewayID(id.rawValue)
        }
        guard registry.gateway(for: id) == nil else {
            throw GatewayRegistryError.duplicate(id)
        }
        let gateway = FleetGateway(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            authConfiguration: registration.authConfiguration,
            transport: registration.transport
        )
        registry.register(gateway)
        // P0-4: persist IMMEDIATELY on Add — the record survives app close /
        // relaunch regardless of connection state. A persistence failure must
        // surface (never silently drop the user's entry); the in-memory
        // registration is rolled back so the UI state and the store agree.
        do {
            try await persist(gateway)
        } catch {
            registry.remove(id)
            throw GatewayRegistryError.recordStoreFailed(Redaction.safeErrorDescription(error))
        }
        return gateway
    }

    public func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        // P1-6: same origin boundary on endpoint edits.
        let normalizedEdits: GatewayEdit
        if let endpoint = edits.endpoint {
            normalizedEdits = GatewayEdit(
                displayName: edits.displayName,
                endpoint: try GatewayEndpoint.normalizedOrigin(from: endpoint),
                authConfiguration: edits.authConfiguration,
                transport: edits.transport
            )
        } else {
            normalizedEdits = edits
        }
        if let existing = registry.gateway(for: id) {
            let proposed = normalizedEdits.applied(to: existing)
            if proposed.transport == .embeddedTailscale, let endpoint = proposed.endpoint {
                try EmbeddedTailnetPolicy.validateEndpoint(endpoint)
            }
        }
        registry.update(id) { gateway in
            let updated = normalizedEdits.applied(to: gateway)
            gateway = updated
        }
        guard let updated = registry.gateway(for: id) else {
            throw GatewayRegistryError.notFound(id)
        }
        // P0-4: edits write through so a rename/endpoint change survives
        // relaunch. No rollback path needed — the in-memory edit already
        // succeeded; a store failure surfaces to the UI.
        try await persist(updated)
        return updated
    }

    public func removeGateway(_ id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        // P1-8: credential cleanup failure must surface — never silently
        // swallowed. Delete the credential first; only on success is the
        // gateway removed, so a cleanup failure leaves the gateway registered
        // (no "removed" UI while a secret may still exist).
        do {
            try await credentials.deleteCredential(for: id)
        } catch {
            throw GatewayRegistryError.credentialStoreFailed(Redaction.safeErrorDescription(error))
        }
        // T3: retire the TLS pin with the credential — a removed gateway
        // must leave no orphaned trust material. Failures surface (same
        // P1-8 contract); missing pin is a no-op at the store level.
        if let pinStore {
            do {
                try await pinStore.deletePin(for: id)
            } catch {
                throw GatewayRegistryError.pinStoreFailed(Redaction.safeErrorDescription(error))
            }
        }
        // P0-4: remove the durable record too — a removed gateway must not
        // resurrect on relaunch.
        if let recordStore {
            do {
                try await recordStore.deleteGatewayRecord(id: id)
            } catch {
                throw GatewayRegistryError.recordStoreFailed(Redaction.safeErrorDescription(error))
            }
        }
        registry.remove(id)
    }

    public func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        do {
            try await credentials.saveCredential(credential, for: id)
        } catch {
            throw GatewayRegistryError.credentialStoreFailed(Redaction.safeErrorDescription(error))
        }
        registry.update(id) { gateway in
            gateway.authConfigured = true
            // Preserve the gateway's configured strategy (set by the U2 UI via
            // addGateway registration / updateGateway) — never force-override it.
            // L1 finding #2: force-overriding to .sessionToken here made every
            // UI-selected strategy (e.g. loopback) unreachable.
            gateway.authConfiguration = GatewayAuthConfiguration(
                strategy: gateway.authConfiguration.strategy,
                credentialStored: true
            )
        }
        // P0-4: write the auth flag through to the durable record.
        if let updated = registry.gateway(for: id) {
            try await persist(updated)
        }
    }

    public func clearCredential(for id: GatewayID) async throws {
        guard registry.gateway(for: id) != nil else {
            throw GatewayRegistryError.notFound(id)
        }
        // P2-4: a failed delete must surface — do NOT mark the gateway
        // un-configured while the secret may still exist.
        do {
            try await credentials.deleteCredential(for: id)
        } catch {
            throw GatewayRegistryError.credentialStoreFailed(Redaction.safeErrorDescription(error))
        }
        registry.update(id) { gateway in
            gateway.authConfigured = false
            gateway.authConfiguration = .none
        }
        // P0-4: write the cleared auth flag through to the durable record.
        if let updated = registry.gateway(for: id) {
            try await persist(updated)
        }
    }

    public func hasCredential(for id: GatewayID) async -> Bool {
        (try? await credentials.loadCredential(for: id)) != nil
    }

    public func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
        guard let gateway = registry.gateway(for: id) else {
            throw GatewayRegistryError.notFound(id)
        }
        let credential = try? await credentials.loadCredential(for: id)
        let connection = connectionFactory(gateway, credential)

        let result: GatewayTestResult
        do {
            try await connection.connect()
            let adopted = await connection.adoptedReady()
            // Reflect adopted metadata into the registry entry (capability
            // surface + auth status) — server state is authoritative (spec §5.3).
            registry.update(id) { entry in
                entry.connectionState = .connected
                entry.capabilities = adopted?.capabilities ?? []
                entry.replayEpoch = adopted?.replayEpoch
                entry.authConfigured = credential != nil
            }
            result = GatewayTestResult(
                status: connection.status,
                capabilities: GatewayCapabilities(strings: adopted?.capabilities ?? []),
                serverIdentity: gateway.serverIdentity
            )
        } catch let error as GatewayConnectivityError {
            let status = GatewayStatus(connectivityError: error)
            registry.update(id) { entry in
                entry.connectionState = .failed(status.rawValue)
            }
            result = GatewayTestResult(status: status)
        } catch {
            let status = GatewayStatus.offline
            registry.update(id) { entry in
                entry.connectionState = .failed("\(error)")
            }
            result = GatewayTestResult(status: status)
        }

        // ADR #3 — the probe ALWAYS tears down its connection before
        // returning: `disconnect()` is idempotent and safe from every state
        // (spec §31 "disconnect does not crash"), so this single await covers
        // the success path and every classified-failure path alike. Without
        // it, the probe's WebSocket socket + receive/heartbeat tasks are
        // abandoned after a successful test.
        await connection.disconnect()
        return result
    }

    // MARK: P0-4 — durable record persistence + launch restore

    /// LEGACY MIGRATION TARGET (F2-era; Issue #2 review re-scope): the
    /// default endpoint legacy rows converge onto, supplied as DATA, never
    /// compiled Swift topology. Resolution order:
    /// 1. `HERMES_FLEET_DEFAULT_ENDPOINT` launch environment (explicit
    ///    legacy-migration lane);
    /// 2. the `FleetDefaultEndpoint` key in the app's Info.plist — a PUBLIC
    ///    hostname only (not private topology, not an ATS exception).
    /// Nil/blank at both layers means "no migration target configured".
    ///
    /// IMPORTANT: resolving a target alone does NOT enable migration.
    /// Migration additionally requires `legacyEndpointMigrationEnabled`
    /// (below) — an explicit, OFF-by-default opt-in. A default endpoint
    /// merely being configured must never rewrite a user's persisted private
    /// gateway (Hermes Fleet explicitly supports user-owned LAN/tailnet
    /// gateways).
    nonisolated static var endpointMigrationDefault: String? {
        let env = ProcessInfo.processInfo.environment["HERMES_FLEET_DEFAULT_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        let plist = (Bundle.main.object(forInfoDictionaryKey: "FleetDefaultEndpoint")
            as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plist.isEmpty ? nil : plist
    }

    /// LEGACY MIGRATION OPT-IN (Issue #2 review): OFF by default. When
    /// false (the public/default runtime state), `restorePersistedGateways()`
    /// NEVER rewrites persisted rows, no matter what endpoints they use —
    /// user-owned private/LAN/tailnet gateways survive verbatim. When
    /// explicitly enabled (the one-time legacy Fleet convergence lane), rows
    /// whose hosts classify as legacy private shapes are re-pointed onto
    /// `endpointMigrationDefault` via `EndpointMigration`.
    nonisolated static var legacyEndpointMigrationEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_LEGACY_MIGRATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "1"
    }

    /// Rebuild the in-memory registry from the durable record store.
    /// Idempotent: records whose ID is already registered are skipped, so a
    /// re-run (or an overlap with seeding) never duplicates entries. Restored
    /// gateways are marked `.disconnected` with auth flags re-derived from the
    /// credential store — the record itself is presentation data only.
    public func restorePersistedGateways() async throws -> [FleetGateway] {
        guard let recordStore else { return [] }
        // LEGACY endpoint convergence (F2-era; Issue #2 review re-scope):
        // runs ONLY when BOTH an explicit opt-in flag
        // (HERMES_FLEET_LEGACY_MIGRATION=1) and a migration target are
        // present — a deliberate one-time legacy-state migration lane. The
        // public/default runtime never migrates: user-owned private/LAN/
        // tailnet gateways survive restore verbatim. The target arrives as
        /// DATA from configuration, never compiled topology. Idempotent; a
        // store failure here must NOT brick launch (same tolerance as the
        // restore itself).
        if Self.legacyEndpointMigrationEnabled,
           let defaultEndpoint = Self.endpointMigrationDefault {
            _ = try? await GatewayEndpointMigrationService(recordStore: recordStore)
                .migrateAll(defaultEndpoint: defaultEndpoint)
        }
        let records = try await recordStore.loadGatewayRecords()
        var restored: [FleetGateway] = []
        for record in records {
            let id = GatewayID(rawValue: record.id)
            guard registry.gateway(for: id) == nil else { continue }
            let hasCredential = (try? await credentials.loadCredential(for: id)) != nil
            let gateway = FleetGateway(
                id: id,
                displayName: record.displayName,
                endpoint: URL(string: record.endpoint),
                connectionState: .disconnected,
                authConfigured: hasCredential,
                authConfiguration: GatewayAuthConfiguration(
                    strategy: record.authConfiguration.strategy,
                    credentialStored: hasCredential
                ),
                transport: record.transport
            )
            registry.register(gateway)
            restored.append(gateway)
        }
        return restored
    }

    /// Write one gateway's non-secret record through to the durable store.
    /// No-op when no record store is wired (scripted fleet / tests).
    private func persist(_ gateway: FleetGateway) async throws {
        guard let recordStore else { return }
        try await recordStore.saveGatewayRecord(StoredGatewayRecord(
            id: gateway.id.rawValue,
            displayName: gateway.displayName,
            endpoint: gateway.endpoint?.absoluteString ?? "",
            authConfiguration: gateway.authConfiguration,
            authConfigured: gateway.authConfigured,
            transport: gateway.transport
        ))
    }
}
