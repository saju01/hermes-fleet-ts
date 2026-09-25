import Foundation
import SwiftData
import FleetCore

/// SwiftData-backed non-secret cache (synthesis §12): caches session/event
/// history + seq watermarks + last replay_epoch for relaunch-resume; a stale
/// replay_epoch triggers a fail-closed reset. **Structurally no credentials:
/// every model holds only non-secret transcript/watermark fields — tokens and
/// tickets live exclusively in Keychain (`TokenStoring`), never here.**
///
/// Implements `CacheStoring` (FleetCore) so the replay/service layer and the
/// app composition root depend on the protocol, not on SwiftData (mirrors the
/// M7 seam pattern).
///
/// Concurrency: this is an `actor` owning a `ModelContainer` (@unchecked
/// Sendable). Each operation creates its own `ModelContext` inside the actor,
/// so a context is never shared across concurrency contexts (SwiftData
/// requirement). The cache is intentionally small and bounded (transcripts +
/// watermarks per registered gateway).
public actor SwiftDataCacheStore: CacheStoring, GatewayRecordStoring {
    /// The SwiftData container backing this cache. In-memory in tests /
    /// previews; file-backed in the app with NSFileProtectionComplete +
    /// backup-exclusion applied to the store file.
    let container: ModelContainer

    /// Where the file-backed store lives (nil for in-memory). Used to apply
    /// and verify file-protection attributes. Immutable and Sendable, so it is
    /// `nonisolated` — readable without crossing the actor boundary.
    nonisolated public let storeURL: URL?

    public init(container: ModelContainer, storeURL: URL? = nil) {
        self.container = container
        self.storeURL = storeURL
    }

    // MARK: CacheStoring

    public func saveHistory(_ history: SessionHistory, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        // Replace semantics: delete any existing transcript for this pair,
        // then insert the fresh rows in order.
        let descriptor = FetchDescriptor<CachedMessageRow>()
        let existing = try ctx.fetch(descriptor)
        for row in existing where row.gatewayID == gatewayID.rawValue && row.sessionID == history.sessionID {
            ctx.delete(row)
        }
        for (index, message) in history.messages.enumerated() {
            ctx.insert(CachedMessageRow(
                gatewayID: gatewayID.rawValue,
                sessionID: history.sessionID,
                order: index,
                role: message.role.wireValue,
                text: message.text,
                timestamp: message.timestamp,
                rowID: message.rowID,
                displayKind: message.displayKind,
                reasoning: message.reasoning,
                toolName: message.toolName,
                toolContext: message.toolContext,
                reactionsData: Self.encodeReactions(message.reactions),
                clientID: message.clientID
            ))
        }
        try ctx.save()
    }

    public func loadHistory(sessionID: String, for gatewayID: GatewayID) async throws -> SessionHistory? {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedMessageRow>())
        let matching = rows
            .filter { $0.gatewayID == gatewayID.rawValue && $0.sessionID == sessionID }
            .sorted { $0.order < $1.order }
        guard !matching.isEmpty else { return nil }
        let messages = matching.map { row in
            SessionMessage(
                role: SessionMessageRole(wire: row.role),
                text: row.text,
                timestamp: row.timestamp,
                rowID: row.rowID,
                displayKind: row.displayKind,
                reasoning: row.reasoning,
                toolName: row.toolName,
                toolContext: row.toolContext,
                reactions: Self.decodeReactions(row.reactionsData),
                clientID: row.clientID
            )
        }
        return SessionHistory(sessionID: sessionID, count: messages.count, messages: messages)
    }

    // MARK: R10-T2 reactions column codec

    /// One persisted reaction entry (Codable mirror of `MessageReaction`).
    private struct CachedReaction: Codable {
        let emoji: String
        let author: String
        let at: Double?
    }

    /// `[MessageReaction]?` → JSON string. nil stays nil; an EMPTY list
    /// encodes as `"[]"` so "disclosed none" survives the round trip
    /// distinct from "not disclosed".
    nonisolated private static func encodeReactions(_ reactions: [MessageReaction]?) -> String? {
        guard let reactions else { return nil }
        let entries = reactions.map { CachedReaction(emoji: $0.emoji, author: $0.author, at: $0.at) }
        guard let data = try? JSONEncoder().encode(entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// JSON string → `[MessageReaction]?`. nil / undecodable → nil (honest
    /// not-disclosed); `"[]"` → `[]` (disclosed none).
    nonisolated private static func decodeReactions(_ json: String?) -> [MessageReaction]? {
        guard let json, let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([CachedReaction].self, from: data)
        else { return nil }
        return entries.map { MessageReaction(emoji: $0.emoji, author: $0.author, at: $0.at) }
    }

    public func deleteHistory(sessionID: String, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedMessageRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue && row.sessionID == sessionID {
            ctx.delete(row)
        }
        try ctx.save()
    }

    public func saveWatermark(_ watermark: SessionEventWatermark, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedWatermarkRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue && row.sessionID == watermark.sessionID {
            ctx.delete(row)
        }
        ctx.insert(CachedWatermarkRow(
            gatewayID: gatewayID.rawValue,
            sessionID: watermark.sessionID,
            lastSeenSeq: watermark.lastSeenSeq
        ))
        try ctx.save()
    }

    public func loadWatermarks() async throws -> [SessionEventWatermark] {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedWatermarkRow>())
        return rows.map { SessionEventWatermark(sessionID: $0.sessionID, lastSeenSeq: $0.lastSeenSeq) }
    }

    public func clearWatermarks() async throws {
        let ctx = ModelContext(container)
        for row in try ctx.fetch(FetchDescriptor<CachedWatermarkRow>()) {
            ctx.delete(row)
        }
        try ctx.save()
    }

    public func saveReplayEpoch(_ epoch: String?, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        ctx.insert(CachedReplayEpochRow(gatewayID: gatewayID.rawValue, epoch: epoch))
        try ctx.save()
    }

    public func loadReplayEpoch(for gatewayID: GatewayID) async throws -> String? {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>())
        return rows.first { $0.gatewayID == gatewayID.rawValue }?.epoch
    }

    public func resetForReplayEpochChange(gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let messageRows = try ctx.fetch(FetchDescriptor<CachedMessageRow>())
        for row in messageRows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        let watermarkRows = try ctx.fetch(FetchDescriptor<CachedWatermarkRow>())
        for row in watermarkRows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        let epochRows = try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>())
        for row in epochRows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        try ctx.save()
    }

    /// Delete all privacy-bearing cached content but keep the saved gateway
    /// records intact. Credentials are not in this store and remain in the
    /// Keychain until the user removes a gateway.
    public func clearCachedData() async throws {
        let ctx = ModelContext(container)
        for row in try ctx.fetch(FetchDescriptor<CachedMessageRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<CachedWatermarkRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<LearningGraphSnapshotRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<ProjectsSnapshotRow>()) { ctx.delete(row) }
        try ctx.save()
    }
}

// MARK: - HealthStatsStoring (H2 Connection health dashboard)

extension SwiftDataCacheStore: HealthStatsStoring {
    /// Replace the persisted health snapshot for a gateway (one row per
    /// gateway; last writer wins — the accumulator persists after every
    /// transition, so the row is always the latest observed state).
    public func saveHealthStats(_ stats: GatewayHealthStats, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        ctx.insert(CachedHealthStatsRow(
            gatewayID: gatewayID.rawValue,
            currentStateRaw: stats.currentState.rawValue,
            firstObservedAt: stats.firstObservedAt,
            lastTransitionAt: stats.lastTransitionAt,
            connectedMilliseconds: stats.connectedMilliseconds,
            disconnectedMilliseconds: stats.disconnectedMilliseconds,
            reconnectCount: stats.reconnectCount,
            lastDisconnectReason: stats.lastDisconnectReason,
            lastDisconnectAt: stats.lastDisconnectAt,
            lastPingRTTMilliseconds: stats.lastPingRTTMilliseconds,
            averagePingRTTMilliseconds: stats.averagePingRTTMilliseconds,
            pingSampleCount: stats.pingSampleCount
        ))
        try ctx.save()
    }

    public func loadHealthStats(for gatewayID: GatewayID) async throws -> GatewayHealthStats? {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>())
        guard let row = rows.first(where: { $0.gatewayID == gatewayID.rawValue }) else {
            return nil
        }
        return GatewayHealthStats(
            currentState: GatewayStatus(rawValue: row.currentStateRaw) ?? .offline,
            firstObservedAt: row.firstObservedAt,
            lastTransitionAt: row.lastTransitionAt,
            connectedMilliseconds: row.connectedMilliseconds,
            disconnectedMilliseconds: row.disconnectedMilliseconds,
            reconnectCount: row.reconnectCount,
            lastDisconnectReason: row.lastDisconnectReason,
            lastDisconnectAt: row.lastDisconnectAt,
            lastPingRTTMilliseconds: row.lastPingRTTMilliseconds,
            averagePingRTTMilliseconds: row.averagePingRTTMilliseconds,
            pingSampleCount: row.pingSampleCount
        )
    }

    public func deleteHealthStats(for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        try ctx.save()
    }

    // MARK: GatewayRecordStoring (P0-4 — durable gateway roster)

    public func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
        let ctx = ModelContext(container)
        // Upsert semantics keyed by gateway id: delete-then-insert (the record
        // is non-secret presentation data — atomicity loss on a crash between
        // the two writes is a benign empty-slot re-add, not data corruption).
        let rows = try ctx.fetch(FetchDescriptor<CachedGatewayRow>())
        for row in rows where row.gatewayID == record.id {
            ctx.delete(row)
        }
        ctx.insert(CachedGatewayRow(
            gatewayID: record.id,
            displayName: record.displayName,
            endpoint: record.endpoint,
            authStrategyRaw: record.authConfiguration.strategy.rawValue,
            transportRaw: record.transport.rawValue,
            credentialStored: record.authConfiguration.credentialStored,
            authConfigured: record.authConfigured
        ))
        try ctx.save()
    }

    public func deleteGatewayRecord(id: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedGatewayRow>())
        for row in rows where row.gatewayID == id.rawValue {
            ctx.delete(row)
        }
        try ctx.save()
    }

    public func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedGatewayRow>())
        return try rows
            .sorted { $0.gatewayID < $1.gatewayID }
            .map { row in
                guard let transport = GatewayTransport(rawValue: row.transportRaw ?? "system") else {
                    throw CocoaError(.coderReadCorrupt)
                }
                return StoredGatewayRecord(
                    id: row.gatewayID,
                    displayName: row.displayName,
                    endpoint: row.endpoint,
                    authConfiguration: GatewayAuthConfiguration(
                        strategy: GatewayAuthConfiguration.Strategy(rawValue: row.authStrategyRaw) ?? .none,
                        credentialStored: row.credentialStored
                    ),
                    authConfigured: row.authConfigured,
                    transport: transport
                )
            }
    }
}

// MARK: - Factories

public extension SwiftDataCacheStore {
    /// In-memory store for tests / previews (no file, no protection needed).
    static func makeInMemory() throws -> SwiftDataCacheStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedMessageRow.self, CachedWatermarkRow.self, CachedReplayEpochRow.self,
                 CachedHealthStatsRow.self, CachedGatewayRow.self, LearningGraphSnapshotRow.self,
                 ProjectsSnapshotRow.self,
            configurations: config
        )
        return SwiftDataCacheStore(container: container)
    }

    /// File-backed store at `storeURL`, applying NSFileProtectionComplete +
    /// backup-exclusion to the store file (spec §12 / synthesis §12). The
    /// parent directory is created if needed. On macOS (host package tests)
    /// file protection is not enforced, but backup exclusion is still applied
    /// and the store round-trips normally.
    static func makeFileBacked(storeURL: URL) throws -> SwiftDataCacheStore {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(
            for: CachedMessageRow.self, CachedWatermarkRow.self, CachedReplayEpochRow.self,
                 CachedHealthStatsRow.self, CachedGatewayRow.self, LearningGraphSnapshotRow.self,
                 ProjectsSnapshotRow.self,
            configurations: config
        )
        // The store file is created eagerly at container init (verified); apply
        // the protection attributes now.
        try CacheStoreProtection.apply(to: storeURL)
        return SwiftDataCacheStore(container: container, storeURL: storeURL)
    }
}

/// Applies the on-disk cache protection attributes required by synthesis §12:
/// NSFileProtectionComplete + backup-excluded, so a device backup never ships
/// the (non-secret but privacy-bearing) transcript cache.
public enum CacheStoreProtection {
    public static func apply(to url: URL) throws {
        var url = url
        // Backup exclusion: the cache is disposable and privacy-bearing; it
        // must not ride along in device/iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)

        // NSFileProtectionComplete: the store file is only readable while the
        // device is unlocked. iOS-only semantic (macOS ignores it).
        #if os(iOS)
        try (url as NSURL).setResourceValue(FileProtectionType.complete, forKey: .fileProtectionKey)
        #endif
    }

    /// Read back the protection attributes for verification (used by the
    /// app-level boundary test on iOS; on macOS file protection reads as nil).
    public static func read(from url: URL) -> (backupExcluded: Bool?, fileProtection: String?) {
        let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        return (values?.isExcludedFromBackup, values?.fileProtection?.rawValue)
    }
}
