import Foundation
import os
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI
import UIKit

#if DEBUG && targetEnvironment(simulator)

/// Scripted fleet simulator — DEBUG SIMULATOR builds ONLY (P0-5: a Debug
/// build on a physical device is a live-dogfood lane and must never contain
/// the fake fleet — see FleetServiceGraph.makeDefaultEnvironment).
///
/// U1 acceptance requires the navigation skeleton to be walkable in the
/// simulator: Gateways → Bots → Sessions → Conversation. Without a live Hermes
/// gateway wired with credentials, the real transport would classify every
/// gateway offline and the shell would show empty states end-to-end. This
/// simulator drives the SAME observable `AppEnvironment` runtime and the SAME
/// FleetCore seams with scripted services that return deterministic,
/// in-memory fleet data — so the whole cockpit flow is navigable on a booted
/// simulator. Release builds use the real production graph
/// (`FleetServiceGraph.makeProductionEnvironment`).
extension FleetServiceGraph {

    /// P2-5 UI-test knob: `HERMES_FLEET_ZERO_BOTS=1` makes EVERY scripted
    /// gateway report a healthy roster with ZERO bots, so the all-healthy
    /// all-empty roster state is reachable in a deterministic UI test.
    nonisolated static var zeroBotsEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_ZERO_BOTS"] == "1"
    }

    /// P2-6 UI-test knob: `HERMES_FLEET_SAVE_FAIL=1` makes the scripted
    /// registry's save path (add/update/saveCredential) throw, so the form's
    /// save-failure retry UX is reachable in a deterministic UI test.
    nonisolated static var saveFailEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_SAVE_FAIL"] == "1"
    }

    static func makeSimulatorEnvironment() -> AppEnvironment {
        // Scripted registry: in-memory credential store (no Keychain writes).
        let credentials = InMemoryCredentialStore()
        let baseRegistry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                ScriptedGatewayConnection(gatewayID: gateway.id)
            }
        )
        // P2-6: when the save-fail knob is set, wrap the registry so the
        // add/edit save path throws (the UI test then verifies the form keeps
        // the sheet open, preserves non-secret fields, and surfaces the error).
        let registry: any GatewayRegistryManaging = if FleetServiceGraph.saveFailEnabled {
            FailingSaveRegistry(inner: baseRegistry)
        } else {
            baseRegistry
        }
        // Scripted union roster: FleetRosterService over scripted per-gateway
        // sessions (real M8 aggregation, scripted transport + roster RPCs).
        let roster: any FleetRosterProviding = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                ScriptedRosterSession(gatewayID: gateway.id)
            }
        )
        // Scripted session.list read path for Bot detail.
        let sessionList: any SessionListProviding = ScriptedSessionListService()
        // In-memory cache (scripted; no file-backed store in the simulator).
        // Doubles as the health-stats store: scripted connections do not emit
        // transport health events, so the dashboard shows live scripted state
        // with "no data yet" stats — honest for the DEBUG walkthrough.
        let cacheStore = try! SwiftDataCacheStore.makeInMemory()
        let cache: any CacheStoring = cacheStore
        let health = GatewayHealthStatsAccumulator(store: cacheStore)

        return AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            sessionList: sessionList,
            connectionFactory: { gateway, _ in
                ScriptedGatewayConnection(gatewayID: gateway.id)
            },
            conversationFactory: { gateway, _ in
                ScriptedConversationSession(gatewayID: gateway.id)
            },
            kanbanWatcherFactory: { _ in
                ScriptedKanbanWatcher()
            },
            managementSeamFactory: { gateway in
                ScriptedManagementSeam(gatewayID: gateway.id)
            },
            learningSeamFactory: { gateway in
                ScriptedLearningSeam(gatewayID: gateway.id)
            },
            learningSnapshotStore: cacheStore,
            projectsSeamFactory: { gateway in
                ScriptedProjectsSeam(gatewayID: gateway.id)
            },
            projectsSnapshotStore: cacheStore,
            botModeChatFactory: { gateway in
                ScriptedBotModeChatSeam(gatewayID: gateway.id)
            },
            botProfileFactory: { gateway in
                ScriptedBotProfileSeam(gatewayID: gateway.id)
            },
            roomSourceFactory: { gateway in
                ScriptedRoomSource(gatewayID: gateway.id)
            },
            // Slice 4: interactive room engine (durable log, send/rename/
            // disband/stop/retry/approve counters) — DEBUG simulator only.
            roomCommandFactory: { gateway in
                ScriptedRoomEngine.shared
            },
            roomDriverStatusFactory: { gateway in
                ScriptedRoomEngine.shared
            },
            // Slice 5 (D19): scripted RoomLink engine — env-knobbed:
            // HERMES_FLEET_ROOMLINK=unsupported renders the honest
            // unsupported state; default is a supported direct/TLS catalog.
            roomLinkFactory: { gateway in
                ScriptedRoomLinkEngine.shared
            },
            health: health,
            seedRegistrations: FleetServiceGraph.zeroGatewaysEnabled
                ? []
                : (FleetServiceGraph.singleGatewayEnabled
                    ? [ScriptedFleet.registrations[0]]
                    : ScriptedFleet.registrations),
            // R10-T4: scripted voice seam (env-knobbed) so the mic button,
            // authorization gate and transcript review are walkable
            // deterministically in the simulator + UI tests — no live speech.
            voiceEngineFactory: { ScriptedVoiceEngine.shared }
        )
    }
}

/// R10-T4 — scripted voice engine (DEBUG simulator only), env-knobbed:
/// - `HERMES_FLEET_VOICE_DENIED=1`: authorization reports denied (the honest
///   gate UI renders, no capture ever starts).
/// - `HERMES_FLEET_VOICE_TRANSCRIPT=1`: an authorized mic tap returns a fixed
///   FINAL transcript after a short delay (lands in the review chip).
/// - default: authorized, no transcript (listening state renders until the
///   tap-to-stop, which returns nil).
final class ScriptedVoiceEngine: VoiceTranscribing, @unchecked Sendable {
    static let shared = ScriptedVoiceEngine()

    private let lock = NSLock()
    private var _listening = false
    private var _stopRequested = false
    private var _spoken: [String] = []

    private var denied: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_VOICE_DENIED"] == "1"
    }
    private var scriptedTranscript: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_VOICE_TRANSCRIPT"] == "1"
    }

    // Sync lock helpers (NSLock is unavailable from async contexts).
    private func tryBeginListening() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _listening { return false }
        _listening = true
        _stopRequested = false
        return true
    }
    private func endListening() {
        lock.lock(); defer { lock.unlock() }
        _listening = false
    }
    private var stopRequestedFlag: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopRequested
    }
    private func requestStop() {
        lock.lock(); defer { lock.unlock() }
        _stopRequested = true
    }
    private func recordSpoken(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _spoken.append(text)
    }

    func authorizationStatus() async -> VoiceAuthorization { denied ? .denied : .authorized }
    func requestAuthorization() async -> VoiceAuthorization { denied ? .denied : .authorized }

    func transcribe() async throws -> VoiceTranscript? {
        guard tryBeginListening() else { throw VoiceError.alreadyListening }
        defer { endListening() }
        if scriptedTranscript {
            try? await Task.sleep(for: .milliseconds(400))
            return VoiceTranscript(text: "Scripted voice transcript for review", isFinal: true)
        }
        // Default: listen until the user taps stop (an honest "nothing
        // recognized" nil — no fabricated transcript).
        while !stopRequestedFlag {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func stopTranscribing() async {
        requestStop()
    }

    func speak(text: String) async throws {
        recordSpoken(text)
    }
    func stopSpeaking() async {}
    var isSpeaking: Bool { false }

    var spokenTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _spoken
    }
}

/// t_3b321b7b — scripted kanban board watcher (DEBUG simulator only): a
/// small static board with a self-updating event stream so the read-only
/// board view is walkable without a live gateway. Presentation data only.
/// t_624b81cd: also scripts the board LIST + client-side pinning so the
/// board selector is walkable deterministically (two boards, "R10
/// Maintenance" active).
private final class ScriptedKanbanWatcher: KanbanBoardWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<KanbanEventBatch>.Continuation] = [:]
    private var pinned: String?
    /// UI-test knob: `HERMES_FLEET_KANBAN_LIVE_UPDATES=1` enables the scripted
    /// live-update ticker (default off — deterministic walkthroughs).
    private let liveUpdatesEnabled =
        ProcessInfo.processInfo.environment["HERMES_FLEET_KANBAN_LIVE_UPDATES"] == "1"

    private static let scriptedBoards = KanbanBoardList(
        boards: [
            KanbanBoardSummary(
                slug: "hermes-fleet-r10", name: "R10 Maintenance",
                isCurrent: true, total: 5),
            KanbanBoardSummary(
                slug: "side-quests", name: "Side Quests",
                isCurrent: false, total: 2),
        ],
        current: "hermes-fleet-r10")

    func fetchBoards() async throws -> KanbanBoardList {
        Self.scriptedBoards
    }

    func pinBoard(_ slug: String?) async {
        unlocked { pinned = slug }
    }

    func snapshot() async throws -> KanbanBoardSnapshot {
        let board: String? = unlocked { pinned }
        // Side Quests (the non-active scripted board) gets a distinct,
        // smaller snapshot so switching visibly changes the board content.
        if board == "side-quests" {
            return KanbanBoardSnapshot(
                columns: ["todo", "done"],
                cardsByColumn: [
                    "todo": [
                        KanbanCard(
                            id: "t_side01", title: "Scripted: side quest one",
                            status: "todo", assignee: "apple-dev",
                            priority: 1, createdAt: 1_780_003_600, latestSummary: nil),
                    ],
                    "done": [
                        KanbanCard(
                            id: "t_side02", title: "Scripted: side quest two",
                            status: "done", assignee: "apple-design",
                            priority: 1, createdAt: 1_779_996_400, latestSummary: nil),
                    ],
                ],
                latestEventID: 2,
                now: 1_780_014_400
            )
        }
        return KanbanBoardSnapshot(
            columns: ["triage", "todo", "ready", "running", "blocked", "review", "done"],
            cardsByColumn: [
                "todo": [
                    KanbanCard(id: "t_script01", title: "Scripted: port kanban stream client", status: "todo", assignee: "apple-dev", priority: 2, createdAt: 1_780_000_000, latestSummary: "Event-stream client pattern ported from the dashboard plugin contract."),
                    KanbanCard(id: "t_script02", title: "Scripted: read-only board view", status: "todo", assignee: "apple-design", priority: 1, createdAt: 1_780_003_600, latestSummary: nil)
                ],
                "running": [
                    KanbanCard(id: "t_script03", title: "Scripted: live reconnect coverage", status: "running", assignee: "apple-qa", priority: 3, createdAt: 1_780_007_200, latestSummary: "Reconnect resumes from the cursor — no events lost across the gap.")
                ],
                "review": [
                    KanbanCard(id: "t_script04", title: "Scripted: design review pass", status: "review", assignee: "apple-design", priority: 2, createdAt: 1_780_010_800, latestSummary: "Gold Fleet tokens applied; columns as horizontal lanes.")
                ],
                "done": [
                    KanbanCard(id: "t_script05", title: "Scripted: domain models", status: "done", assignee: "apple-dev", priority: 1, createdAt: 1_779_996_400, latestSummary: nil)
                ]
            ],
            latestEventID: 41,
            now: 1_780_014_400
        )
    }

    func changeEvents() async -> AsyncStream<KanbanEventBatch> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
            if liveUpdatesEnabled {
                // Ticker: one scripted event every 3s (capped ids so the
                // activity strip stays small).
                Task.detached { [weak self] in
                    var n = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        guard let self, !Task.isCancelled else { return }
                        let batch = KanbanEventBatch(
                            events: [KanbanChangeEvent(
                                id: 100 + n, taskID: n % 2 == 0 ? "t_script03" : "t_script01",
                                kind: "heartbeat", createdAt: nil)],
                            cursor: 100 + n)
                        n += 1
                        let targets = self.unlocked { Array(self.continuations.values) }
                        for target in targets { target.yield(batch) }
                    }
                }
            }
        }
    }

    func stop() async {
        let targets = unlocked { () -> [AsyncStream<KanbanEventBatch>.Continuation] in
            let targets = Array(continuations.values)
            continuations.removeAll()
            return targets
        }
        for target in targets { target.finish() }
    }

    /// Async-safe scoped lock helper (NSLock is unavailable in async
    /// contexts on this toolchain).
    private func unlocked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Scripted read-only `session.list` for Bot detail (DEBUG only).
/// Returns the scripted fleet's sessions for a route; never mutates.
///
/// UI-test knob: `HERMES_FLEET_SESSIONS_FAIL=<gateway-id>[,<gateway-id>…]`
/// makes the read FAIL for the listed gateways (a classified `RosterError`),
/// so the Chats refresh-failure surfaces (dogfood finding 1) are reachable in
/// a deterministic UI test — one gateway fails while another still holds
/// usable sessions (the compact inline surface).
private struct ScriptedSessionListService: SessionListProviding {
    static var failingGatewayIDs: Set<String> {
        let raw = ProcessInfo.processInfo.environment["HERMES_FLEET_SESSIONS_FAIL"] ?? ""
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        if Self.failingGatewayIDs.contains(route.gatewayID.rawValue) {
            throw RosterError.notConnected
        }
        return ScriptedFleet.sessions(on: route)
    }
}

/// True Bots Mode: scripted canonical-chat seam (DEBUG simulator only).
/// Deterministic fixture: one canonical "Bot Chat" row per profile
/// (id "botchat-<profile>"), env knob HERMES_FLEET_BOT_CHAT_FAIL forces
/// lookup failures so the fail-closed UI path is walkable.
final class ScriptedBotModeChatSeam: BotModeChatProviding, @unchecked Sendable {
    private let gatewayID: GatewayID
    private var created = Set<String>()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    func lookupCanonicalChat(profile: String) async throws -> CanonicalLookup {
        if FleetServiceGraph.botChatLookupFails {
            throw RosterError.rpcFailed("fixture lookup failure")
        }
        // The default profile already has one; other profiles return empty
        // first (confirmed miss → creation path) unless previously created.
        if profile != "default" && !created.contains(profile) {
            return CanonicalLookup(rows: [])
        }
        return CanonicalLookup(rows: [
            CanonicalLookupRow(
                id: "botchat-\(profile)",
                resolvedID: nil,
                title: BotModeContract.canonicalChatTitle,
                preview: "Scripted canonical chat",
                messageCount: 3)
        ])
    }

    func createCanonicalChat(profile: String) async throws -> String {
        created.insert(profile)
        return "botchat-\(profile)"
    }
}

/// R9-T5/T6: scripted management seam (DEBUG simulator only) — fixture
/// cron jobs + skills catalog with in-memory mutations so both panes are
/// fully walkable without a live gateway. Presentation data only.
///
/// Slice 3 (D13): the cron store is PROFILE-SCOPED like the real gateway
/// (cron/jobs.py:59-64 — each profile's jobs live in its own store). The
/// fixture seeds general jobs plus deterministic `[bot:<owner>]` routine
/// jobs so the bot Routines surface has walkable content: list returns
/// the general jobs plus the requesting profile's namespaced routines.
final class ScriptedManagementSeam: GatewayManagementProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [CronJob]
    private var disabled: Set<String>

    init(gatewayID: GatewayID) {
        // The outage gateway gets no jobs (honest partial-fleet state);
        // healthy gateways get the fixture set.
        if gatewayID.rawValue == "arch" {
            jobs = []
            disabled = []
        } else {
            jobs = [
                CronJob(
                    jobID: "script-cron-1", name: "Fleet morning briefing",
                    schedule: "every day at 07:00",
                    nextRunAt: "2026-09-05T07:00:00", lastRunAt: "2026-09-04T07:00:03",
                    lastStatus: "ok", isEnabled: true, state: "enabled",
                    promptPreview: "Summarize fleet activity since yesterday and flag stuck cards."),
                CronJob(
                    jobID: "script-cron-2", name: "Weekly digest",
                    schedule: "every monday at 09:00",
                    nextRunAt: nil, lastRunAt: nil, lastStatus: nil,
                    isEnabled: false, state: "paused", promptPreview: nil),
                // Slice 3 fixture routines — the researcher bot's store.
                CronJob(
                    jobID: "script-routine-1", name: "[bot:researcher] Morning briefing",
                    schedule: "every day at 07:00",
                    nextRunAt: "2026-09-08T07:00:00", lastRunAt: "2026-09-07T07:00:02",
                    lastStatus: "ok", isEnabled: true, state: "enabled",
                    promptPreview: "Summarize overnight fleet activity for the researcher.",
                    deliver: "bot-chat:researcher", repeatDisplay: "forever"),
                CronJob(
                    jobID: "script-routine-2", name: "[bot:researcher] Weekly digest",
                    schedule: "every monday at 09:00",
                    nextRunAt: nil, lastRunAt: nil, lastStatus: nil,
                    isEnabled: false, state: "paused", promptPreview: nil,
                    pausedReason: "paused by user"),
                // Slice 3 fixture routine — the default bot's store, with a
                // deterministic failure association (last_fire_error).
                CronJob(
                    jobID: "script-routine-3", name: "[bot:default] Evening recap",
                    schedule: "every day at 21:00",
                    nextRunAt: "2026-09-08T21:00:00", lastRunAt: "2026-09-07T21:00:04",
                    lastStatus: "fire_failed", isEnabled: true, state: "enabled",
                    promptPreview: "Recap the day's fleet activity.",
                    deliver: "bot-chat:default", repeatDisplay: "forever",
                    lastFireError: "provider auth missing for openrouter"),
            ]
            disabled = ["test-driven-development"]
        }
    }

    /// Async-safe scoped lock helper (NSLock is unavailable in async
    /// contexts on this toolchain — same helper as ScriptedKanbanWatcher).
    private func unlocked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func listCronJobs(profile: String?) async throws -> [CronJob] {
        unlocked {
            // Profile-scoped store: general jobs plus THIS profile's
            // namespaced routines (the [bot:<profile>] namespace is the
            // ownership association on the real wire too).
            jobs.filter { job in
                guard let profile else { return true }
                if let parsed = BotRoutineNamespace.parse(job.name) {
                    return parsed.owner.lowercased() == profile.lowercased()
                }
                return true
            }
        }
    }

    func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob {
        let job = CronJob(
            jobID: "script-cron-\(UUID().uuidString.prefix(6))",
            name: draft.name, schedule: draft.schedule,
            nextRunAt: "2026-09-05T07:00:00", isEnabled: true, state: "enabled",
            promptPreview: String(draft.prompt.prefix(80)),
            deliver: draft.deliver,
            repeatDisplay: draft.repeatCount.map { _ in "forever" })
        return unlocked {
            jobs.append(job)
            return job
        }
    }

    func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async throws -> CronJob {
        // Two-phase so the throwing guard runs OUTSIDE the scoped helper
        // (unlocked's body is non-throwing).
        let index = unlocked { jobs.firstIndex { $0.jobID == jobID } }
        guard let index else {
            throw GatewayManagementError.rpcFailed("no such job")
        }
        return unlocked {
            let old = jobs[index]
            let updated = CronJob(
                jobID: old.jobID, name: old.name, schedule: old.schedule,
                nextRunAt: enabled ? "2026-09-05T07:00:00" : nil,
                lastRunAt: old.lastRunAt, lastStatus: old.lastStatus,
                isEnabled: enabled, state: enabled ? "enabled" : "paused",
                promptPreview: old.promptPreview)
            jobs[index] = updated
            return updated
        }
    }

    func deleteCronJob(_ jobID: String, profile: String?) async throws {
        unlocked { jobs.removeAll { $0.jobID == jobID } }
    }

    func fireCronJob(_ jobID: String, profile: String?) async throws {
        // The scripted gateway supports run by default (R9-era fixture
        // behavior the general Cron pane's regression test relies on —
        // a gateway that DOES forward cron.manage run). The launch arg
        // `-fixture-run-now-fails` scripts the REAL 0.21.0 wire answer
        // (methods_tools.py:1033-1057: run not forwarded → err 4016) so
        // the honest unsupported-explanation path is UI-testable against
        // the same shape the live gateway returns.
        if ProcessInfo.processInfo.arguments.contains("-fixture-run-now-fails") {
            throw GatewayManagementError.unsupportedAction("unknown cron action: run")
        }
    }

    func skillsCatalog(profile: String) async throws -> SkillsCatalog {
        // Mirrors the live 0.21.0 server: `skills.manage list` EXCLUDES
        // disabled skills (tools/skills_tool.py:773) with no include flag
        // on the WS handler (methods_tools.py:1916-1919), while
        // `profiles.describe` reports the full installed set with
        // enablement (methods_profiles.py:625-640). The union join in
        // SkillsCatalog restores the disabled names under `installed`.
        let disabledNow = unlocked { disabled }
        let allCategories: [(category: String, skills: [String])] = [
            ("dev", ["codex", "systematic-debugging", "test-driven-development"]),
            ("github", ["github-code-review", "github-pr-workflow", "github-auth"]),
            ("hermes", ["hermes-agent"]),
        ]
        let visibleCategories = allCategories
            .map { (category: $0.category, skills: $0.skills.filter { !disabledNow.contains($0.lowercased()) }) }
            .filter { !$0.skills.isEmpty }
        let described = allCategories.flatMap { $0.skills }
        let enabledByName = Dictionary(
            uniqueKeysWithValues: described.map { name in
                (name.lowercased(), !disabledNow.contains(name.lowercased()))
            })
        return SkillsCatalog(
            unionOf: visibleCategories, describedSkills: enabledByName)
    }

    func setSkill(_ name: String, enabled: Bool, profile: String) async throws -> Bool {
        unlocked {
            if enabled {
                disabled.remove(name.lowercased())
            } else {
                disabled.insert(name.lowercased())
            }
            return enabled
        }
    }
}

/// R9-T7: scripted learning seam (DEBUG simulator only) — a fixture
/// learning journey (mirrors the live mac profile's real shape: learned
/// skills + memory chunks across date buckets) so the Memory Graph is
/// fully walkable without a live gateway. Presentation data only.
final class ScriptedLearningSeam: GatewayLearningProviding, @unchecked Sendable {

    private let state = OSAllocatedUnfairLock(initialState: ScriptedLearningSeam.fixtureGraph())

    init(gatewayID: GatewayID) {}

    func learningGraph(profile: String?) async throws -> LearningGraph {
        state.withLock { $0 }
    }

    func nodeDetail(id: String) async throws -> LearningNodeDetail {
        let isMemory = id.hasPrefix("memory:")
        return LearningNodeDetail(
            id: id,
            kind: isMemory ? "memory" : "skill",
            label: id,
            // Single-word memory body: a double-tap selects the whole
            // chunk, which keeps the UI-test edit-clearing deterministic.
            content: isMemory
                ? "fixturechunk"
                : "---\nname: \(id)\ndescription: Fixture skill for the simulator walkthrough.\n---\n\n(fixture SKILL.md body)")
    }

    func editNode(id: String, content: String) async throws -> String {
        // Wire-truth refusal (learning_mutations.py:150-153): an empty
        // memory body is refused with the real message — the honest UI
        // walkthrough of a gateway refusal, no env hook needed.
        if id.hasPrefix("memory:"), content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GatewayLearningError.mutationFailed("empty memory — use delete to remove it")
        }
        // The fixture graph does not track chunk content; a real reload
        // after edit still succeeds and keeps node count stable.
        return id.hasPrefix("memory:")
            ? "updated memory in MEMORY.md"
            : "updated '\(id)'"
    }

    func deleteNode(id: String) async throws -> String {
        state.withLock { state in
            state = LearningGraph(
                buckets: state.buckets.map { bucket in
                    LearningGraphBucket(
                        index: bucket.index, label: bucket.label, date: bucket.date,
                        category: bucket.category,
                        nodes: bucket.nodes.filter { $0.id != id })
                },
                summary: state.summary)
        }
        return id.hasPrefix("memory:")
            ? "deleted memory from MEMORY.md"
            : "archived '\(id)' — restore with: hermes curator restore \(id)"
    }

    /// A fixture journey shaped like the live payload (buckets with skills
    /// + memories, summary/axis/count) — deterministic.
    static func fixtureGraph() -> LearningGraph {
        var buckets: [LearningGraphBucket] = []
        let plan: [(label: String, date: String, skills: [String], memories: [String])] = [
            ("30 Aug", "30 Aug 2026", ["systematic-debugging"], []),
            ("31 Aug", "31 Aug 2026", ["github-auth"], ["memory:profile:0"]),
            ("1 Sep", "1 Sep 2026", ["codex", "hermes-agent"], ["memory:memory:1"]),
            ("2 Sep", "2 Sep 2026", ["test-driven-development"], ["memory:profile:2"]),
            ("3 Sep", "3 Sep 2026", ["github-code-review", "github-pr-workflow"], []),
            ("4 Sep", "4 Sep 2026", ["ios-xcode-project-pipeline", "swift-and-platform-engineering", "apple-product-factory"], ["memory:memory:3"]),
        ]
        for (index, slice) in plan.enumerated() {
            var nodes: [LearningGraphNode] = slice.skills.map {
                LearningGraphNode(
                    id: $0, label: $0, fullLabel: $0, isMemory: false,
                    meta: "skill · \(slice.date) · x\(2 + index)")
            }
            nodes.append(contentsOf: slice.memories.map {
                LearningGraphNode(
                    id: $0, label: "profile memory", fullLabel: "profile memory",
                    isMemory: true, meta: "memory · \(slice.date)",
                    body: "# profile memory\n\nchunk…")
            })
            buckets.append(LearningGraphBucket(
                index: index, label: slice.label, date: slice.date,
                category: index % 2 == 0 ? "dev" : "software-development",
                nodes: nodes))
        }
        let skillCount = plan.reduce(0) { $0 + $1.skills.count }
        let memoryCount = plan.reduce(0) { $0 + $1.memories.count }
        return LearningGraph(
            buckets: buckets,
            summary: LearningGraphSummary(
                lines: ["\(skillCount) learned skills · \(memoryCount) memories · 9 skill links",
                        "\(memoryCount) memory↔skill links · busiest day 4 Sep · 4 learned"],
                start: "30 Aug 2026", end: "4 Sep 2026",
                totalCount: skillCount + memoryCount))
    }
}

/// R10-T3: scripted projects seam (DEBUG simulator only) — a fixture
/// projects.tree mirroring the live gateway's real shape (an explicit
/// project with two lanes + the "No Project" tier, previews on the
/// overview, hydrated rows on drill-in) so the Projects browser is
/// fully walkable without a live gateway. Presentation data only.
///
/// Failure hook (`HERMES_FLEET_PROJECTS_FAIL=1`) makes every call throw
/// 5061-shaped — the honest offline/error walkthrough for UI tests.
final class ScriptedProjectsSeam: GatewayProjectsProviding, @unchecked Sendable {

    private static let failHook =
        ProcessInfo.processInfo.environment["HERMES_FLEET_PROJECTS_FAIL"] == "1"

    init(gatewayID: GatewayID) {}

    func projectTree(profile: String?) async throws -> ProjectsTree {
        if Self.failHook {
            throw GatewayProjectsError.rpcFailed("profile db locked (5061)")
        }
        return Self.fixtureTree()
    }

    func projectSessions(projectID: String, profile: String?) async throws -> ProjectNode? {
        if Self.failHook {
            throw GatewayProjectsError.rpcFailed("profile db locked (5061)")
        }
        return Self.fixtureTree().projects.first { $0.id == projectID }
            .map(Self.hydrate)
    }

    func completePath(word: String, cwd: String?) async throws -> [PathCompletionItem] {
        if Self.failHook {
            throw GatewayProjectsError.rpcFailed("profile db locked (5061)")
        }
        // Scripted completions for the walkthrough only.
        switch word {
        case "@file:PACK", "@file:Packages/Fle":
            return [
                PathCompletionItem(text: "@folder:Packages/FleetUI/", display: "FleetUI/", meta: "dir"),
                PathCompletionItem(text: "@file:Packages/Module.swift", display: "Module.swift", meta: "Packages"),
            ]
        default:
            return []
        }
    }

    /// Fixture overview (hydrate=False shape: lanes carry no rows).
    static func fixtureTree() -> ProjectsTree {
        let sessionRow = { (id: String, title: String, preview: String, branch: String,
                            started: Double, active: Double, messages: Int, cost: Double) in
            ProjectSessionRow(
                id: id, title: title, preview: preview,
                startedAt: started, lastActive: active, endedAt: nil,
                cwd: "/Users/dev/code/fleet-ios", gitBranch: branch,
                messageCount: messages, toolCallCount: messages / 4,
                inputTokens: messages * 50, outputTokens: messages * 75,
                actualCostUsd: cost, estimatedCostUsd: nil,
                model: "glm-5.3", profile: "default")
        }
        let fleet = ProjectNode(
            id: "proj-fleet", label: "Fleet iOS",
            path: "/Users/dev/code/fleet-ios", color: "#22d3ee",
            isAuto: false, isNoProject: false, sessionCount: 3,
            lastActive: 1_788_550_000, totalTokens: 1_500, totalCostUsd: 0.05,
            repos: [
                ProjectRepoNode(
                    id: "/Users/dev/code/fleet-ios", label: "fleet-ios",
                    path: "/Users/dev/code/fleet-ios", sessionCount: 3,
                    groups: [
                        ProjectLaneNode(
                            id: "/Users/dev/code/fleet-ios::branch::r10-t3",
                            label: "r10-t3", path: "/Users/dev/code/fleet-ios",
                            isMain: false, isKanban: false, sessions: []),
                        ProjectLaneNode(
                            id: "/Users/dev/code/fleet-ios::branch::main",
                            label: "main", path: "/Users/dev/code/fleet-ios",
                            isMain: true, isKanban: false, sessions: []),
                        ProjectLaneNode(
                            id: "/Users/dev/code/fleet-ios::kanban",
                            label: "kanban", path: "/Users/dev/code/fleet-ios",
                            isMain: false, isKanban: true, sessions: []),
                    ]),
            ],
            previewSessions: [
                sessionRow("s1", "WS transport fix", "correlate rpc ids", "r10-t3",
                           1_788_540_000, 1_788_550_000, 12, 0.04),
                sessionRow("s2", "Reactions round 2", "promote newest_role", "main",
                           1_788_500_000, 1_788_510_000, 8, 0.01),
                sessionRow("s3", "Board sweep", "qa findings", "main",
                           1_788_480_000, 1_788_490_000, 5, 0.00),
            ])
        let noProject = ProjectNode(
            id: "__no_project__", label: "No Project", path: nil, color: nil,
            isAuto: false, isNoProject: true, sessionCount: 1,
            lastActive: 1_788_540_000, totalTokens: 500, totalCostUsd: 0.01,
            repos: [
                ProjectRepoNode(
                    id: "__no_project__", label: "No Project", path: nil, sessionCount: 1,
                    groups: [
                        ProjectLaneNode(
                            id: "__no_project__", label: "No Project", path: nil,
                            isMain: false, isKanban: false, sessions: [])]),
            ],
            previewSessions: [
                ProjectSessionRow(
                    id: "s9", title: "Loose scratch chat", preview: "quick question",
                    startedAt: 1_788_530_000, lastActive: 1_788_540_000, endedAt: nil,
                    cwd: "/tmp", gitBranch: "", messageCount: 2, toolCallCount: 0,
                    inputTokens: 200, outputTokens: 300,
                    actualCostUsd: 0.01, estimatedCostUsd: nil,
                    model: "glm-5.3", profile: "default"),
            ])
        return ProjectsTree(
            projects: [noProject, fleet],
            activeID: "proj-fleet",
            scopedSessionIDs: ["s9", "s1", "s2", "s3"])
    }

    /// Fixture drill-in (hydrate=True shape: lanes carry rows).
    static func hydrate(_ node: ProjectNode) -> ProjectNode {
        let rows: [String: ProjectSessionRow] = [
            "s1": ProjectSessionRow(
                id: "s1", title: "WS transport fix", preview: "correlate rpc ids",
                startedAt: 1_788_540_000, lastActive: 1_788_550_000, endedAt: nil,
                cwd: "/Users/dev/code/fleet-ios", gitBranch: "r10-t3",
                messageCount: 12, toolCallCount: 3, inputTokens: 600, outputTokens: 900,
                actualCostUsd: 0.04, estimatedCostUsd: nil,
                model: "glm-5.3", profile: "default"),
            "s2": ProjectSessionRow(
                id: "s2", title: "Reactions round 2", preview: "promote newest_role",
                startedAt: 1_788_500_000, lastActive: 1_788_510_000, endedAt: nil,
                cwd: "/Users/dev/code/fleet-ios", gitBranch: "main",
                messageCount: 8, toolCallCount: 0, inputTokens: 100, outputTokens: 200,
                actualCostUsd: 0.01, estimatedCostUsd: nil,
                model: "glm-5.3", profile: "default"),
            "s3": ProjectSessionRow(
                id: "s3", title: "Board sweep", preview: "qa findings",
                startedAt: 1_788_480_000, lastActive: 1_788_490_000, endedAt: nil,
                cwd: "/Users/dev/code/fleet-ios", gitBranch: "main",
                messageCount: 5, toolCallCount: 1, inputTokens: 250, outputTokens: 375,
                actualCostUsd: 0.0, estimatedCostUsd: nil,
                model: "glm-5.3", profile: "default"),
        ]
        let hydratedRepos = node.repos.map { repo in
            ProjectRepoNode(
                id: repo.id, label: repo.label, path: repo.path,
                sessionCount: repo.sessionCount,
                groups: repo.groups.map { lane in
                    ProjectLaneNode(
                        id: lane.id, label: lane.label, path: lane.path,
                        isMain: lane.isMain, isKanban: lane.isKanban,
                        sessions: lane.id.hasSuffix("::kanban")
                            ? []
                            : lane.label.replacements(rowCount: lane.isMain ? 2 : 1).compactMap { rows[$0] })
                })
        }
        return ProjectNode(
            id: node.id, label: node.label, path: node.path, color: node.color,
            isAuto: node.isAuto, isNoProject: node.isNoProject,
            sessionCount: node.sessionCount, lastActive: node.lastActive,
            totalTokens: node.totalTokens, totalCostUsd: node.totalCostUsd,
            repos: hydratedRepos, previewSessions: [])
    }
}

/// Tiny helper: deterministic session-id pick per lane for the fixture.
private extension String {
    func replacements(rowCount: Int) -> [String] {
        switch self {
        case "r10-t3": return rowCount >= 1 ? ["s1"] : []
        case "main": return rowCount >= 2 ? ["s2", "s3"] : (rowCount == 1 ? ["s2"] : [])
        default: return []
        }
    }
}

/// Scripted per-gateway conversation session (DEBUG only): a scripted
/// connection + a scripted conversation client that streams a canned turn
/// (message.start → deltas → message.complete) after each prompt.submit, a
/// no-op replay (nothing to replay), and scripted history. Makes the U3
/// Conversation canvas fully walkable in the simulator without a live gateway.
private struct ScriptedConversationSession: ConversationSessionProviding, ApprovalsCapable, ConversationToolingCapable, AttachmentStagingCapable, ReactionCapable, SlashCommandCapable, BotDisplayCapable {
    let gatewayID: GatewayID
    private let client: ScriptedConversationClient
    /// R9-T1: scripted approvals seam (records respond/yolo calls so the
    /// approval banner is fully walkable in the simulator + UI tests).
    let approvalsBox = ScriptedApprovalsBox()
    /// R9-T2/T3/T4: scripted tooling seam (fixture models + usage +
    /// steer/title/branch recorders).
    let toolingBox = ScriptedToolingBox()
    /// R10-T1: scripted attachment-staging seam (fixture refs + failure
    /// hooks so the composer tray is fully walkable in the simulator + UI
    /// tests).
    let attachmentsBox = ScriptedAttachmentSeam()
    /// R10-T2: scripted reaction seam (records react calls + failure hook so
    /// long-press Tapback is fully walkable in the simulator + UI tests).
    let reactionsBox = ScriptedReactionSeam()
    /// Issue #4: scripted Hermes skill discovery/completion/dispatch so the
    /// slash palette is walkable in simulator UI tests without a gateway.
    let slashCommandsBox: ScriptedSlashCommandBox
    /// Simple mode: scripted Bot Desktop (synthetic RFB + in-memory lease).
    let display: any BotDisplayProviding = ScriptedBotDisplay()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
        self.client = ScriptedConversationClient(gatewayID: gatewayID)
        self.slashCommandsBox = ScriptedSlashCommandBox(gatewayID: gatewayID)
        // R10-T2: keep the scripted reaction seam's durable-row state in
        // lockstep with the fixture resume projection (the seeded 👀 on
        // row 9101), so a same-emoji re-send retracts exactly like the DB
        // layer would.
        reactionsBox.seedReactions(
            [MessageReaction(emoji: "👀", author: "user", at: 1_788_600_000)],
            rowID: "9101")
    }

    var status: GatewayStatus {
        // The `arch` gateway is scripted UNREACHABLE (partial-outage demo).
        gatewayID.rawValue == "arch" ? .offline : .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        gatewayID.rawValue == "arch"
            ? nil
            : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if gatewayID.rawValue == "arch" {
            throw GatewayConnectivityError.unreachable
        }
    }

    func disconnect() async {}

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }

    func reauthenticate() async throws {
        if gatewayID.rawValue == "arch" {
            throw GatewayConnectivityError.unreachable
        }
    }

    var conversation: any ConversationProviding {
        client
    }

    var approvals: any ApprovalsProviding {
        approvalsBox
    }

    /// R9-T2/T3/T4: scripted tooling seam.
    var tooling: any ConversationToolingProviding {
        toolingBox
    }

    /// R10-T1: scripted attachment-staging seam.
    var attachments: any AttachmentStagingProviding {
        attachmentsBox
    }

    /// R10-T2: scripted reaction seam.
    var reactions: any ReactionProviding {
        reactionsBox
    }

    var slashCommands: any SlashCommandProviding {
        slashCommandsBox
    }

    /// R9-T1 UI-test hook: push a scripted approval request into the
    /// conversation event stream (drives the banner deterministically).
    func pushApprovalRequest(_ request: ApprovalRequest) {
        client.pushApprovalRequest(request)
    }

    var replay: any ReplayProviding {
        ScriptedReplay(gatewayID: gatewayID)
    }

    var history: any SessionHistoryProviding {
        ScriptedHistory(gatewayID: gatewayID)
    }
}

/// Issue #4 scripted slash capability. The submitted expanded message still
/// travels through the regular scripted conversation client, preserving the
/// same streaming transcript path as a live Hermes gateway.
///
/// UI-test-only fixtures (DEBUG simulator builds) are selected by the
/// existing scripted route/session combinations: workstation/default/s2 has
/// no skills, workstation/researcher/s1 fails discovery, and render-box
/// models a stale dispatch.
private final class ScriptedSlashCommandBox: SlashCommandProviding, @unchecked Sendable {
    private enum FixtureMode: Equatable {
        case normal
        case noSkills
        case discoveryFailure
        case staleDispatch
    }

    private let catalog: [SlashCommandSuggestion] = [
        SlashCommandSuggestion(
            text: "/hermes-change-review",
            description: "Review a change against its issue",
            kind: .skill),
        SlashCommandSuggestion(
            text: "/hermes-plan",
            description: "Build an implementation plan",
            kind: .skill),
    ]

    private let gatewayID: GatewayID

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    /// Keep failure fixtures tied to existing scripted session rows so the
    /// UI tests do not depend on process-launch configuration. The normal
    /// workstation/default/s1 conversation remains the happy-path fixture.
    private func mode(for sessionID: String?) -> FixtureMode {
        if gatewayID.rawValue == "render-box" {
            return .staleDispatch
        }
        switch sessionID {
        case "workstation.default.s2":
            return .noSkills
        case "workstation.researcher.s1":
            return .discoveryFailure
        default:
            return .normal
        }
    }

    func skillCatalog(sessionID: String?) async throws -> [SlashCommandSuggestion] {
        switch mode(for: sessionID) {
        case .discoveryFailure:
            throw SlashCommandError.rpcFailed("scripted skill discovery failed")
        case .noSkills:
            return []
        case .normal, .staleDispatch:
            return catalog
        }
    }

    func completeSkills(sessionID: String?, text: String) async throws -> [SlashCommandSuggestion] {
        switch mode(for: sessionID) {
        case .discoveryFailure:
            throw SlashCommandError.rpcFailed("scripted skill discovery failed")
        case .noSkills:
            return []
        case .normal, .staleDispatch:
            break
        }
        let query = text.drop(while: { $0 == "/" }).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return catalog.filter { $0.text.dropFirst().lowercased().hasPrefix(query.lowercased()) }
    }

    func dispatchSkill(sessionID: String, name: String, argument: String) async throws -> SkillCommandDispatch {
        let canonical = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if mode(for: sessionID) == .staleDispatch {
            throw SlashCommandError.notSkillCommand(canonical)
        }
        guard catalog.contains(where: { $0.text.dropFirst().lowercased() == canonical.lowercased() }) else {
            throw SlashCommandError.notSkillCommand(canonical)
        }
        let display = argument.isEmpty ? "/" + canonical : "/" + canonical + " " + argument
        return SkillCommandDispatch(
            name: canonical,
            message: "[Scripted expanded skill: \(canonical)]\n\(argument)",
            display: display)
    }
}

/// Scripted `ConversationProviding` that streams a canned turn after submit.
private final class ScriptedConversationClient: ConversationProviding, @unchecked Sendable {
    /// Issue #5 UI fixture: deliberately crosses incomplete bold, list, table,
    /// and fenced-code boundaries while keeping the wire shape as ordinary
    /// message.delta text. It is enabled only by an explicit UI-test launch
    /// argument; the default simulator response remains unchanged for all
    /// existing slash, attachment, reaction, and conversation tests.
    private static let issue5RichMarkdownChunks: [String] = [
        "# Streaming rich text\n\n",
        "Assistant content arrives as **half-finished bold",
        "** and *italic* with ~~strike~~ and `inline code`.\n\n",
        "## Structure\n\n- first list item\n- [",
        "] partial task\n1. ordered item\n2. second",
        " ordered item\n\n> blockquote\n\n---\n\n",
        "### Code\n\n```",
        "swift\nlet answer = \"streaming\"\n",
        "```\n\n### Table\n\n| Feature | State |\n| --- |",
        " --- |\n| Markdown | active |\n\n",
        "[Safe link](https://github.com/AIowa-LLC/hermes-fleet/issues/5)\n\n",
        "![pixel](https://example.invalid/tracker.png)\n",
        "[unsafe](javascript:alert(1))\n\n",
        "<script>alert(\"inert\")</script>\n\n",
        "Malformed **bold and [link"
    ]

    private let gatewayID: GatewayID
    private let streamBox = ScriptedEventStreamBox()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    var events: AsyncStream<ConversationEvent> {
        streamBox.stream
    }

    /// R9-T1 UI-test hook: yield a scripted approval.request into the event
    /// fan-out (the banner renders from the same conversation stream).
    func pushApprovalRequest(_ request: ApprovalRequest) {
        streamBox.yield(.approvalRequested(
            sessionID: request.sessionID,
            requestID: request.requestID,
            command: request.command,
            detail: request.detail,
            choices: request.choices
        ))
    }

    func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
        // R9-T2: honor the per-session model override (the sticky pick rides
        // here) — the scripted session reflects the requested model back.
        ConversationSession(
            sessionID: "scripted-\(gatewayID.rawValue)",
            storedSessionID: "stored-scripted-\(gatewayID.rawValue)",
            messageCount: 0,
            messages: [],
            model: model ?? "scripted-model",
            provider: provider ?? "simulator",
            profileName: profile
        )
    }

    func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
        // R10-T2: fixture durable rows (row_id-stamped, one carrying a
        // seeded reaction) so long-press Tapback targets DURABLE rows in
        // the simulator + UI tests — mirroring what a real session.resume
        // projection carries.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_REACTION_FIXTURE"] == "1" {
            return ConversationSession(
                sessionID: sessionID,
                storedSessionID: "stored-\(sessionID)",
                messageCount: 2,
                messages: [
                    SessionMessage(
                        role: .user,
                        text: "Reaction fixture row — long-press me",
                        rowID: "9100"),
                    SessionMessage(
                        role: .assistant,
                        text: "Fixture answer with a seeded reaction.",
                        rowID: "9101",
                        reactions: [MessageReaction(emoji: "👀", author: "user", at: 1_788_600_000)]),
                ],
                model: "scripted-model",
                provider: "simulator",
                profileName: nil
            )
        }
        // R10-T3 round 2 UI-test hook: fixture durable rows carrying an
        // `@file:` ref whose ABSOLUTE path lands inside the scripted
        // projects tree's repo (so the tap-through highlights its
        // containing project) — mirrors what a real transcript row with
        // an attached-file reference looks like on the wire.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_FILEREF_FIXTURE"] == "1" {
            return ConversationSession(
                sessionID: sessionID,
                storedSessionID: "stored-\(sessionID)",
                messageCount: 2,
                messages: [
                    SessionMessage(
                        role: .user,
                        text: "Please review @file:/Users/dev/code/fleet-ios/Packages/FleetUI/ProjectsView.swift before merging",
                        rowID: "9200"),
                    SessionMessage(
                        role: .assistant,
                        text: "Reviewed. The ProjectsView drills via projects.project_sessions.",
                        rowID: "9201"),
                ],
                model: "scripted-model",
                provider: "simulator",
                profileName: nil
            )
        }
        return ConversationSession(
            sessionID: sessionID,
            storedSessionID: "stored-\(sessionID)",
            messageCount: 0,
            messages: [],
            model: "scripted-model",
            provider: "simulator",
            profileName: nil
        )
    }

    /// t_8401d3c3: the scripted simulator never gaps — nothing to resume.
    func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] {
        []
    }

    func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
        // R9-T1 demo hook (simulator only): `HERMES_FLEET_APPROVAL_DEMO=1`
        // makes every scripted turn also raise an approval request mid-turn
        // — the banner is then fully walkable in the simulator + UI tests.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_APPROVAL_DEMO"] == "1" {
            let fixtureBearer = ["fixture", "bearer", "demo"].joined(separator: "-")
            Task { [streamBox, fixtureBearer] in
                try? await Task.sleep(for: .milliseconds(400))
                streamBox.yield(.approvalRequested(
                    sessionID: sessionID,
                    requestID: "scripted-approval-1",
                    // Fixture token is FAKE (demo only) — allowline-annotated
                    // because the redaction path must be exercised with a
                    // token-shaped bearer fixture, even though it is inert.
                    command: "curl -H 'Authorization: Bearer \(fixtureBearer)' https://api.example.invalid",
                    detail: "Scripted credential-bearing command (simulator demo)",
                    choices: ["once", "session", "always", "deny"]
                ))
            }
        }
        // Stream a canned assistant turn shortly after submit (async so the
        // view model's event subscription is attached). R9-T3: a mid-turn
        // session.usage tick exercises the live context meter path.
        Task { [streamBox] in
            try? await Task.sleep(for: .milliseconds(250))
            streamBox.yield(.usageUpdate(
                sessionID: sessionID,
                usage: SessionUsageSnapshot(
                    model: "hermes",
                    input: 12_000,
                    output: 1_200,
                    total: 13_200,
                    calls: 2,
                    contextUsed: 52_000,
                    contextMax: 120_000,
                    contextPercent: 43
                )
            ))
            streamBox.yield(.messageStart(sessionID: sessionID))
            if ProcessInfo.processInfo.arguments.contains("-issue5-markdown-fixture") {
                // Keep the initial empty assistant row on screen long enough
                // for the UI fixture to verify that the preceding user row
                // remains literal before the rich answer grows past it.
                try? await Task.sleep(for: .milliseconds(1_500))
                var fullMarkdown = ""
                for chunk in Self.issue5RichMarkdownChunks {
                    fullMarkdown += chunk
                    streamBox.yield(.messageDelta(sessionID: sessionID, text: chunk, rendered: nil))
                }
                streamBox.yield(.statusUpdate(sessionID: sessionID, kind: "process", text: "complete"))
                streamBox.yield(.messageComplete(
                    sessionID: sessionID,
                    text: fullMarkdown,
                    status: nil,
                    error: nil
                ))
                return
            }
            // Simple mode: a prompt mentioning the browser drives two
            // scripted browser tool steps (one live browser card).
            if text.localizedCaseInsensitiveContains("browser") {
                streamBox.yield(.toolStart(sessionID: sessionID, toolID: "b1", name: "browser_navigate", context: "example.com", argsText: nil))
                streamBox.yield(.toolComplete(sessionID: sessionID, toolID: "b1", name: "browser_navigate", summary: nil))
                streamBox.yield(.toolStart(sessionID: sessionID, toolID: "b2", name: "browser_snapshot", context: "example.com", argsText: nil))
                streamBox.yield(.toolComplete(sessionID: sessionID, toolID: "b2", name: "browser_snapshot", summary: nil))
            }
            streamBox.yield(.messageDelta(sessionID: sessionID, text: "Hello from the scripted fleet. ", rendered: nil))
            // D-2 fix (t_9ce36690): echo the PROMPT TEXT only — drop the
            // appended @file:/@folder: ref TOKENS from the echoed text (the
            // ref marker AND its path; refs stay visible in the user bubble
            // + its tap-through chip, and the wire shape is unchanged — refs
            // are staged server-side at pick time). Empirically (9-run
            // experiment matrix), an assistant bubble — a textSelection-
            // enabled Text — carrying a long unbreakable @file: path token
            // makes every iOS 26 AX identifier-snapshot take >30s, wedging
            // XCUITest queries (R10AttachmentTray line-79 timeout). Short
            // plain-text echoes keep the "You said: <text>" contract
            // asserted by HappyPath/P0-7.
            // The dispatch expansion is model-facing scaffolding. Keep the
            // scripted assistant's human-facing echo focused on the user's
            // argument so the simulator proves that expansion never leaks
            // into the transcript UI.
            let visibleEchoSource: String
            if text.hasPrefix("[Scripted expanded skill:"),
               let newline = text.firstIndex(of: "\n") {
                visibleEchoSource = String(text[text.index(after: newline)...])
            } else {
                visibleEchoSource = text
            }
            let echoBase = visibleEchoSource
                .split(whereSeparator: \.isWhitespace)
                .filter { !$0.contains("@file:") && !$0.contains("@folder:") }
                .joined(separator: " ")
            streamBox.yield(.messageDelta(sessionID: sessionID, text: "You said: ", rendered: nil))
            streamBox.yield(.messageDelta(sessionID: sessionID, text: echoBase, rendered: nil))
            streamBox.yield(.statusUpdate(sessionID: sessionID, kind: "process", text: "complete"))
            streamBox.yield(.messageComplete(
                sessionID: sessionID,
                text: "Hello from the scripted fleet. You said: \(echoBase)",
                status: nil,
                error: nil
            ))
        }
        return PromptSubmission(status: "streaming")
    }

    func interrupt(sessionID: String) async throws -> InterruptResult {
        InterruptResult(status: "interrupted")
    }
}

/// R9-T1: scripted approvals seam (DEBUG simulator). Records every
/// respond/yolo call (thread-safe) and succeeds — the banner's wire path is
/// observable from UI tests via the recorded state.
final class ScriptedApprovalsBox: ApprovalsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _respondChoices: [String] = []
    private var _yoloStates: [Bool] = []

    var respondChoices: [String] {
        lock.lock(); defer { lock.unlock() }
        return _respondChoices
    }
    var yoloStates: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _yoloStates
    }

    // Sync-record helpers (NSLock is unavailable from async contexts).
    private func recordRespond(_ raw: String) {
        lock.lock(); defer { lock.unlock() }
        _respondChoices.append(raw)
    }
    private func recordYolo(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        _yoloStates.append(enabled)
    }

    func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
        recordRespond(choice.rawValue)
        return 1
    }

    func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool {
        recordYolo(enabled)
        return enabled
    }

    /// R9-T1 rework: restore seam — no scripted pendings by default (the
    /// demo approval arrives as a push event, not a reconnect restore).
    func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        []
    }
}

/// R9-T2/T3/T4: scripted tooling seam (DEBUG simulator). Deterministic
/// fixture models for the picker; records steer/rename/branch calls; usage
/// readback with a mid-turn context gauge. Thread-safe recorders.
final class ScriptedToolingBox: ConversationToolingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _steerTexts: [String] = []
    private var _renames: [String] = []
    private var _branches: [String?] = []

    var steerTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _steerTexts
    }
    var renames: [String] {
        lock.lock(); defer { lock.unlock() }
        return _renames
    }
    var branches: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _branches
    }

    private func recordSteer(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _steerTexts.append(text)
    }
    private func recordRename(_ title: String) {
        lock.lock(); defer { lock.unlock() }
        _renames.append(title)
    }
    private func recordBranch(_ name: String?) {
        lock.lock(); defer { lock.unlock() }
        _branches.append(name)
    }

    /// Fixture models (deterministic, mono ids — the picker's UI-test set).
    func modelChoices(sessionID: String?) async throws -> [ModelChoice] {
        [
            ModelChoice(model: "hermes", provider: "nous", providerName: "Nous Research", isCurrent: true),
            ModelChoice(model: "hermes-mini", provider: "nous", providerName: "Nous Research", isCurrent: false),
            ModelChoice(model: "openai/gpt-5", provider: "openrouter", providerName: "OpenRouter", isCurrent: false),
            ModelChoice(model: "anthropic/claude-sonnet-4", provider: "openrouter", providerName: "OpenRouter", isCurrent: false),
        ]
    }

    /// Usage readback with a mid-context gauge (fixture: 38% of 120k).
    func usage(sessionID: String) async throws -> SessionUsageSnapshot {
        SessionUsageSnapshot(
            model: "hermes",
            input: 12_000,
            output: 3_400,
            total: 16_300,
            calls: 4,
            contextUsed: 45_600,
            contextMax: 120_000,
            contextPercent: 38
        )
    }

    /// Fixture breakdown mirroring context_breakdown.py:163's category set.
    func contextBreakdown(sessionID: String) async throws -> ContextBreakdown {
        ContextBreakdown(
            categories: [
                ContextBreakdownCategory(id: "system_prompt", label: "System prompt", tokens: 5_200),
                ContextBreakdownCategory(id: "tool_definitions", label: "Tool definitions", tokens: 9_800),
                ContextBreakdownCategory(id: "rules", label: "Rules", tokens: 1_400),
                ContextBreakdownCategory(id: "skills", label: "Skills", tokens: 2_100),
                ContextBreakdownCategory(id: "mcp", label: "MCP", tokens: 0),
                ContextBreakdownCategory(id: "subagent_definitions", label: "Subagent definitions", tokens: 1_100),
                ContextBreakdownCategory(id: "memory", label: "Memory", tokens: 3_400),
                ContextBreakdownCategory(id: "conversation", label: "Conversation", tokens: 22_600),
            ].filter { $0.tokens > 0 },
            contextMax: 120_000,
            contextPercent: 38,
            contextUsed: 45_600,
            estimatedTotal: 45_600,
            model: "hermes"
        )
    }

    func steer(sessionID: String, text: String) async throws -> Bool {
        recordSteer(text)
        return true
    }

    func renameSession(sessionID: String, title: String) async throws -> String {
        recordRename(title)
        return title
    }

    func branchSession(sessionID: String, name: String?) async throws -> ConversationSession {
        recordBranch(name)
        return ConversationSession(
            sessionID: "scripted-branch-\(sessionID)",
            storedSessionID: "stored-\(sessionID)-branch",
            messageCount: 2,
            messages: [
                SessionMessage(role: .user, text: "hello fixture"),
                SessionMessage(role: .assistant, text: "Hi from the scripted branch."),
            ],
            model: "hermes",
            provider: "simulator",
            profileName: nil
        )
    }
}

/// R10-T1: scripted attachment-staging seam (DEBUG simulator only).
/// Deterministic fixture `@file:` refs shaped like the live gateway's
/// `file.attach` result (methods_prompt.py:1350-1395); records every attach
/// call so UI tests assert the wire-shaped ask. Failure hook
/// (`HERMES_FLEET_ATTACHMENT_FAIL=1`) makes every attach throw 4018-shaped
/// `tooLarge` so the never-silent error banner is walkable.
final class ScriptedAttachmentSeam: AttachmentStagingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _attachCalls: [(method: String, sessionID: String, name: String)] = []

    /// Recorded attach calls (method, session, name) — UI-test observability.
    var attachCalls: [(method: String, sessionID: String, name: String)] {
        lock.lock(); defer { lock.unlock() }
        return _attachCalls
    }

    private func record(_ method: String, _ sessionID: String, _ name: String) {
        lock.lock(); defer { lock.unlock() }
        _attachCalls.append((method, sessionID, name))
    }

    private var failAll: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_ATTACHMENT_FAIL"] == "1"
    }

    func attachFile(sessionID: String, name: String, dataURL: String) async throws -> StagedFileAttachment {
        record("file.attach", sessionID, name)
        if failAll {
            throw AttachmentStagingError.tooLarge(detail: "fixture: file too large (UI-test failure hook)")
        }
        let display = (name as NSString).lastPathComponent
        return StagedFileAttachment(
            name: display,
            path: "/srv/hermes/profiles/default/attachments/\(display)",
            refPath: "attachments/\(display)",
            refText: "@file:attachments/\(display)",
            uploaded: true)
    }

    func attachImageBytes(sessionID: String, filename: String, dataURL: String) async throws -> StagedImageAttachment {
        record("image.attach_bytes", sessionID, filename)
        if failAll {
            throw AttachmentStagingError.tooLarge(detail: "fixture: image too large (UI-test failure hook)")
        }
        return StagedImageAttachment(
            path: "/srv/hermes/images/upload_fixture_1.png",
            name: "upload_fixture_1.png",
            count: 1,
            byteCount: 1_024,
            width: 64,
            height: 64,
            tokenEstimate: 320)
    }

    func attachPDF(sessionID: String, filename: String, dataURL: String) async throws -> StagedPDFAttachment {
        record("pdf.attach", sessionID, filename)
        if failAll {
            throw AttachmentStagingError.tooLarge(detail: "fixture: PDF too large (UI-test failure hook)")
        }
        return StagedPDFAttachment(
            filename: (filename as NSString).lastPathComponent,
            pagesAttached: 2,
            pages: [
                StagedPDFPage(path: "/srv/hermes/images/pdf_p1_1.png", pageNumber: 1,
                              name: "pdf_p1_1.png", width: 1275, height: 1650),
                StagedPDFPage(path: "/srv/hermes/images/pdf_p2_2.png", pageNumber: 2,
                              name: "pdf_p2_2.png", width: 1275, height: 1650),
            ],
            count: 2)
    }

    func detachImage(sessionID: String, path: String) async throws -> DetachedImageState {
        DetachedImageState(detached: true, count: 0)
    }
}

/// R10-T2: scripted reaction seam — records every `message.react` call so
/// UI tests assert the wire-shaped ask (row_id vs newest_role, emoji vs
/// null). Failure hook (`HERMES_FLEET_REACTION_FAIL=1`) makes every react
/// throw 4040-shaped `messageNotFound` so the never-silent error banner +
/// optimistic rollback are walkable. Result discipline mirrors the server:
/// the post-write reaction list reflects the per-author single-reaction
/// semantics (re-send same emoji retracts).
final class ScriptedReactionSeam: ReactionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _reactCalls: [(sessionID: String, target: MessageReactionTarget, emoji: String?)] = []
    private var _reactions: [String: [MessageReaction]] = [:]

    /// Recorded react calls — UI-test observability.
    var reactCalls: [(sessionID: String, target: MessageReactionTarget, emoji: String?)] {
        lock.lock(); defer { lock.unlock() }
        return _reactCalls
    }

    /// Seed a row's reactions (fixture history adoption).
    func seedReactions(_ reactions: [MessageReaction], rowID: String) {
        lock.lock(); defer { lock.unlock() }
        _reactions[rowID] = reactions
    }

    private var failAll: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_REACTION_FAIL"] == "1"
    }

    func react(
        sessionID: String,
        target: MessageReactionTarget,
        emoji: String?
    ) async throws -> MessageReactionResult {
        let failing = failAll
        let result: MessageReactionResult = try lock.withLock {
            _reactCalls.append((sessionID, target, emoji))
            // Resolve the durable row the write lands on (mirrors
            // latest_message_row_id for newest_role — the scripted fleet has
            // no DB, so live targets land on the fixed fixture row).
            let rowID = target.rowID ?? "9101"
            var reactions = _reactions[rowID] ?? []
            if !failing, let emoji {
                // Server semantics (hermes_state.set_message_reaction):
                // re-sending the same emoji retracts; different replaces.
                let hadSame = reactions.contains { $0.author == "user" && $0.emoji == emoji }
                reactions.removeAll { $0.author == "user" }
                if !hadSame {
                    reactions.append(MessageReaction(emoji: emoji, author: "user", at: 1_788_600_000))
                }
                _reactions[rowID] = reactions
            } else if !failing {
                reactions.removeAll { $0.author == "user" }
                _reactions[rowID] = reactions
            }
            return MessageReactionResult(rowID: rowID, reactions: reactions)
        }
        if failing {
            throw ReactionError.messageNotFound("fixture: message not found (UI-test failure hook)")
        }
        return result
    }
}

/// Thread-safe fan-out box bridging the scripted client's event channel to
/// the `AsyncStream`s the view model subscribes to. P0-7: each `stream`
/// access returns a FRESH stream registered in the fan-out (deregistered on
/// termination), mirroring the real transport's multi-subscriber event
/// channel — a re-entered conversation (new view model after pop) gets a
/// live pipe instead of the previous consumer's dead one.
private final class ScriptedEventStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ConversationEvent>.Continuation] = [:]

    init() {}

    var stream: AsyncStream<ConversationEvent> {
        lock.lock()
        defer { lock.unlock() }
        let (stream, continuation) = AsyncStream<ConversationEvent>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    private func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        _ = continuations.removeValue(forKey: id)
    }

    func yield(_ event: ConversationEvent) {
        lock.lock()
        defer { lock.unlock() }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}

/// Scripted no-op replay (DEBUG only) — nothing was missed in the simulator.
private struct ScriptedReplay: ReplayProviding {
    let gatewayID: GatewayID
    func watermarks() async -> [SessionEventWatermark] { [] }
    func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
}

/// Scripted read-only history (DEBUG only). Canonical "Bot Chat" fixture
/// sessions (id prefix "botchat-") carry a short deterministic transcript so
/// the canonical-chat state is reviewable in the simulator; other sessions
/// stay honestly empty.
private struct ScriptedHistory: SessionHistoryProviding {
    let gatewayID: GatewayID
    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        guard sessionID.hasPrefix("botchat-") else {
            return SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        let profile = String(sessionID.dropFirst("botchat-".count))
        let messages = [
            SessionMessage(
                role: .user,
                text: "Morning check-in — anything blocking you?",
                timestamp: 1_757_240_000,
                rowID: "botchat-hist-1"),
            SessionMessage(
                role: .assistant,
                text: "Nothing blocking. I finished the \(profile) review pass and queued the summary.",
                timestamp: 1_757_240_060,
                rowID: "botchat-hist-2"),
            SessionMessage(
                role: .user,
                text: "Great — ping me if the batch job drifts.",
                timestamp: 1_757_240_180,
                rowID: "botchat-hist-3"),
        ]
        return SessionHistory(sessionID: sessionID, count: messages.count, messages: messages)
    }
    func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
        SessionStatus.parse(output: "Session ID: \(sessionID)")
    }
}

/// Deterministic in-memory fleet for the simulator: three gateways (two
/// healthy, one unreachable) each with a couple of bots (profiles) and
/// sessions, so every navigation destination and the partial-outage roster
/// state have content.
/// Deterministic 8x8 PNG fixtures for the scripted pet surface (#9) —
/// tiny valid PNGs (magenta / solid green) standing in for pet.thumb
/// idle frames. Distinct per gateway to prove route-scoped caching.
enum ScriptedPetPNG {
    static let magenta = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR4nGP4z7DoP8MoQS4BAPMYqAH2vyKxAAAAAElFTkSuQmCC")!
    static let green = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR4nGNgOFHxn2GUIJcAAIjXj8EqoCrvAAAAAElFTkSuQmCC")!
}

enum ScriptedFleet {
    static let registrations: [GatewayRegistration] = [
        GatewayRegistration(
            id: GatewayID(rawValue: "workstation"),
            displayName: "Workstation",
            endpoint: URL(string: "http://127.0.0.1:8642")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "render-box"),
            displayName: "Render Box",
            endpoint: URL(string: "http://127.0.0.1:9900")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "arch"),
            displayName: "Lab Node",
            endpoint: URL(string: "http://127.0.0.1:9910")!
        ),
    ]

    static func profiles(on gatewayID: GatewayID) -> [ProfileDescriptor] {
        // Slice 2: profiles created through the scripted management seam in
        // THIS app process join the roster on the next refresh (created bots
        // must become visible; the seam mints them).
        let created = ScriptedBotProfileSeamStore.shared.createdDescriptors(on: gatewayID)
        // #7: appearance writes (metadata + avatar asset state) through the
        // scripted seam overlay the static descriptors — a roster refresh
        // after an avatar Save reflects gateway-authoritative appearance.
        func overlay(_ descriptor: ProfileDescriptor) -> ProfileDescriptor {
            guard let appearance = ScriptedBotProfileSeamStore.shared.appearanceOverlay(
                on: gatewayID, profile: descriptor.name) else { return descriptor }
            var uiMeta = descriptor.uiMeta ?? [:]
            uiMeta[BotModeContract.botsMetaKey] = .object(appearance.metadata.toWire())
            var revisions = descriptor.uiMetaRevisions ?? MetadataRevisions(revisions: [:])
            revisions.revisions[BotModeContract.botsMetaKey] =
                (revisions.revisions[BotModeContract.botsMetaKey] ?? 0) + 1
            return ProfileDescriptor(
                name: descriptor.name,
                path: descriptor.path,
                isDefault: descriptor.isDefault,
                model: descriptor.model,
                provider: descriptor.provider,
                profileDescription: descriptor.profileDescription,
                displayName: descriptor.displayName,
                skillCount: descriptor.skillCount,
                hasAvatar: appearance.hasAvatar,
                lastSession: descriptor.lastSession,
                gatewayRunning: descriptor.gatewayRunning,
                canonicalSession: descriptor.canonicalSession,
                workerSession: descriptor.workerSession,
                uiMetaRevisions: revisions,
                uiMeta: uiMeta)
        }
        switch gatewayID.rawValue {
        case "workstation":
            return [
                overlay(ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 12, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                )),
                overlay(ProfileDescriptor(
                    name: "researcher", path: "~/.hermes/profiles/researcher",
                    isDefault: false, model: "hermes", provider: "openrouter",
                    displayName: "Researcher", skillCount: 8, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "researcher")
                )),
            ] + created
        case "render-box":
            return [
                overlay(ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 10, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                )),
            ] + created
        default:
            return created
        }
    }

    static func sessions(on route: Route) -> [SessionSummary] {
        switch route.gatewayID.rawValue {
        case "workstation":
            if route.profileSlug.rawValue == "researcher" {
                return [
                    SessionSummary(
                        id: "workstation.researcher.s1", title: "Research briefing",
                        preview: "Researcher profile scripted discovery fixture.", startedAt: 1_755_000_000,
                        messageCount: 8, source: "ios"
                    ),
                ]
            }
            return [
                ScriptedFleet.session(on: "default"),
                SessionSummary(
                    id: "workstation.default.s2", title: "Replay plan review",
                    preview: "Discussing the reconnect/replay design.", startedAt: 1_755_000_000,
                    messageCount: 24, source: "ios"
                ),
            ]
        default:
            return [ScriptedFleet.session(on: route.profileSlug.rawValue)]
        }
    }

    private static func session(on slug: String) -> SessionSummary {
        SessionSummary(
            id: "workstation.\(slug).s1", title: "Fleet setup",
            preview: "Initial conversation about the Hermes fleet.",
            startedAt: 1_754_000_000, messageCount: 6, source: "ios"
        )
    }
}

/// Scripted single-gateway connection: connects instantly, adopts a ready
/// payload, never touches the network. Used for the Gateways screen lifecycle
/// and the registry probe. The `arch` gateway is scripted UNREACHABLE so the
/// simulator demonstrates the partial-outage state (§31).
private struct ScriptedGatewayConnection: GatewayConnectivityProviding {
    let gatewayID: GatewayID

    private var isOutage: Bool { gatewayID.rawValue == "arch" }

    var status: GatewayStatus {
        // Scripted connections report online immediately for healthy
        // gateways; the outage gateway reports offline so the observable
        // lifecycle state reflects partial availability.
        isOutage ? .offline : .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        isOutage ? nil : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if isOutage {
            throw GatewayConnectivityError.unreachable
        }
        if FleetServiceGraph.connectSyncEnabled, gatewayID.rawValue == "workstation" {
            ScriptedConnectSyncStore.shared.markRecovered()
        }
        // No-op: scripted connect succeeds instantly.
    }

    func disconnect() async {
        // No-op: scripted disconnect is safe from every state (spec §31).
    }

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
}

/// State for the deterministic connect→roster recovery UI scenario.
final class ScriptedConnectSyncStore: @unchecked Sendable {
    static let shared = ScriptedConnectSyncStore()
    private let lock = NSLock()
    private var _recovered = false

    var recovered: Bool {
        lock.lock(); defer { lock.unlock() }
        return _recovered
    }

    func markRecovered() {
        lock.lock(); defer { lock.unlock() }
        _recovered = true
    }
}

/// P2-6 DEBUG-only seam: a `GatewayRegistryManaging` wrapper that throws on
/// the save path (add / update / saveCredential) while forwarding read +
/// teardown operations to the inner registry. Lets the deterministic UI test
/// drive the form's save-failure retry UX without a real transport failure.
private struct FailingSaveRegistry: GatewayRegistryManaging {
    let inner: any GatewayRegistryManaging

    func allGateways() async -> [FleetGateway] { await inner.allGateways() }
    func gateway(for id: GatewayID) async -> FleetGateway? { await inner.gateway(for: id) }
    func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
        throw GatewayRegistryError.credentialStoreFailed("injected save failure")
    }
    func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        throw GatewayRegistryError.credentialStoreFailed("injected save failure")
    }
    func removeGateway(_ id: GatewayID) async throws { try await inner.removeGateway(id) }
    func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {
        throw GatewayRegistryError.credentialStoreFailed("injected save failure")
    }
    func clearCredential(for id: GatewayID) async throws { try await inner.clearCredential(for: id) }
    func hasCredential(for id: GatewayID) async -> Bool { await inner.hasCredential(for: id) }
    func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
        try await inner.testConnection(to: id)
    }
}

/// Scripted per-gateway roster session: real M8 session shape, scripted
/// `profiles.list` / `session.list` responses. The `arch` gateway is scripted
/// UNREACHABLE so the union roster refresh classifies it offline while the
/// healthy gateways still aggregate (spec §31 partial availability).
///
/// P2-5: when `HERMES_FLEET_ZERO_BOTS=1`, EVERY gateway reports a healthy,
/// zero-bot roster (no outage, no profiles) so the all-healthy all-empty state
/// is reachable for the No-Bots regression UI test.
private struct ScriptedRosterSession: GatewayRosterSession {
    let gatewayID: GatewayID

    /// FOS-4 UI-test knob: `HERMES_FLEET_AUTH_GATEWAY=1` makes the `arch`
    /// gateway a classified AUTH-REQUIRED failure (close 4401 shape) so the
    /// Home Needs You section (auth episode) is deterministically walkable.
    private var isAuthOutage: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_AUTH_GATEWAY"] == "1"
    }

    private var isOutage: Bool {
        if FleetServiceGraph.connectSyncEnabled,
           gatewayID.rawValue == "workstation",
           !ScriptedConnectSyncStore.shared.recovered {
            return true
        }
        guard !FleetServiceGraph.zeroBotsEnabled else { return false }
        return gatewayID.rawValue == "arch"
    }

    private var hasNoBots: Bool { FleetServiceGraph.zeroBotsEnabled }

    private var authFailure: Bool { isAuthOutage && gatewayID.rawValue == "arch" }

    var status: GatewayStatus {
        if authFailure { return .authenticationRequired }
        return isOutage ? .offline : .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        isOutage ? nil : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if authFailure {
            throw GatewayConnectivityError.authenticationRequired
        }
        if isOutage {
            throw GatewayConnectivityError.unreachable
        }
    }

    func disconnect() async {}

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }

    func fetchProfiles() async throws -> [ProfileDescriptor] {
        if isOutage { throw RosterError.notConnected }
        if hasNoBots { return [] }
        return ScriptedFleet.profiles(on: gatewayID)
    }

    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        if isOutage { throw RosterError.notConnected }
        return ScriptedFleet.sessions(on: route)
    }
}

/// Shared record of profiles created through scripted management seams in
/// this app process, so the scripted roster can surface created bots on the
/// next refresh (deterministic create-visible flow) — and of appearance
/// writes (metadata + avatar asset state) so a roster refresh after an
/// avatar Save reflects gateway-authoritative state (#7 UI journeys).
final class ScriptedBotProfileSeamStore: @unchecked Sendable {
    static let shared = ScriptedBotProfileSeamStore()
    private let lock = NSLock()
    private var created: [GatewayID: [ProfileDescriptor]] = [:]
    /// Appearance writes through scripted seams, keyed gateway → profile:
    /// hermes-bots metadata + whether an avatar asset exists.
    private var appearance: [GatewayID: [String: (metadata: BotModeMetadata, hasAvatar: Bool)]] = [:]

    func record(gatewayID: GatewayID, name: String, title: String?) {
        lock.lock(); defer { lock.unlock() }
        var list = created[gatewayID] ?? []
        guard !list.contains(where: { $0.name == name }) else { return }
        list.append(ProfileDescriptor(
            name: name,
            path: "~/.hermes/profiles/\(name)",
            isDefault: false,
            displayName: title ?? name))
        created[gatewayID] = list
    }

    func recordAppearance(
        gatewayID: GatewayID, profile: String,
        metadata: BotModeMetadata, hasAvatar: Bool) {
        lock.lock(); defer { lock.unlock() }
        appearance[gatewayID, default: [:]][profile] = (metadata, hasAvatar)
    }

    /// The authoritative scripted appearance for a profile, if a scripted
    /// seam ever wrote one (nil = keep the static descriptor).
    func appearanceOverlay(on gatewayID: GatewayID, profile: String)
        -> (metadata: BotModeMetadata, hasAvatar: Bool)? {
        lock.lock(); defer { lock.unlock() }
        return appearance[gatewayID]?[profile]
    }

    func createdDescriptors(on gatewayID: GatewayID) -> [ProfileDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return created[gatewayID] ?? []
    }
}

/// True Bots Mode slice 2: scripted bot-profile management seam (DEBUG
/// simulator only) — in-memory metadata/section/avatar state with the same
/// semantics as the real client (CAS conflict on stale revision, model
/// confirmation knob, partial-success outcomes). Presentation data only.
final class ScriptedBotProfileSeam: BotProfileManaging, BotSectionRegistryLoading, BotSectionRegistryWriting, BotPetManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let gatewayID: GatewayID
    private var metadataByProfile: [String: BotModeMetadata] = [:]
    private var revisionByProfile: [String: Int] = [:]
    private var avatarBytesByProfile: [String: Data] = [:]
    private var sections: [BotSection] = []
    private var sectionsRevision = 0

    /// Env knob: `HERMES_FLEET_MODEL_CONFIRM=1` forces the model
    /// confirmation handshake on every model write.
    private var modelConfirmForced: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_MODEL_CONFIRM"] == "1"
    }

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
        if gatewayID.rawValue == "workstation" {
            sections = [
                BotSection(id: "sec-script-1", name: "Clients"),
                BotSection(id: "sec-script-2", name: "Research"),
            ]
            sectionsRevision = 1
            var researcher = BotModeMetadata()
            researcher.title = "Researcher"
            researcher.sectionID = "sec-script-2"
            metadataByProfile["researcher"] = researcher
            revisionByProfile["researcher"] = 2
        }
    }

    func describeProfile(_ profile: String) async throws -> BotProfileDescription {
        BotProfileDescription(
            name: profile,
            descriptionText: metadataByProfile[profile]?.descriptionText,
            soul: "Scripted SOUL for \(profile).",
            defaultModel: "hermes",
            provider: "nous",
            skills: [
                .init(name: "code", enabled: true),
                .init(name: "web", enabled: false),
            ],
            toolsets: [.init(name: "fs", label: "Files", toolCount: 4, enabled: true)],
            mcpServers: [.init(name: "script-srv", enabled: true, transport: "http")]
        )
    }

    func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
        try await configureProfile(profile, edit: edit, confirmExpensiveModel: false)
    }

    func configureProfile(
        _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
    ) async throws -> BotProfileEditOutcome {
        var applied: [String: Bool] = [:]
        if let metadata = edit.metadata {
            let expected = edit.metadataExpectedRevision
            let current: Int
            let appliedMeta: Bool
            (current, appliedMeta) = applyMetadata(profile, metadata: metadata, expected: expected)
            if !appliedMeta {
                throw BotSectionSyncError.conflict(
                    "expected revision \(expected ?? 0) but the gateway has \(current)")
            }
            applied["ui_meta"] = true
            recordAppearanceWrite(profile)
        }
        if edit.soul != nil { applied["soul"] = true }
        if edit.descriptionText != nil { applied["description"] = true }
        if edit.hasModelSection {
            if modelConfirmForced && !confirmExpensiveModel {
                return BotProfileEditOutcome(
                    appliedSections: [], failedSections: [],
                    confirmRequired: true,
                    confirmMessage: "Scripted expensive-model confirmation")
            }
            applied["model"] = true
        }
        if edit.disabledSkills != nil { applied["skills"] = true }
        if edit.enabledToolsets != nil { applied["toolsets"] = true }
        if edit.enabledMCPServers != nil { applied["mcp_servers"] = true }
        return BotProfileEditOutcome(edit: edit, applied: applied)
    }

    func createProfile(_ spec: BotCreateSpec) async throws -> String {
        seedProfile(spec.name, metadata: BotModeMetadata(
            title: spec.title, descriptionText: spec.descriptionText))
        return spec.name
    }

    func uploadAvatar(_ profile: String, dataURL: String) async throws {
        storeAvatarBytes(profile, dataURL: dataURL)
        recordAppearanceWrite(profile)
    }

    func clearAvatar(_ profile: String) async throws {
        dropAvatarBytes(profile)
        recordAppearanceWrite(profile)
    }

    func avatarData(_ profile: String) async throws -> Data? {
        currentAvatarBytes(profile)
    }

    // MARK: i7-gapfill R1 — avatar upload / portrait generation surface

    /// The scripted fleet is asset-capable (mirrors a real gateway that
    /// speaks profiles.set_asset), so the Photos / Files / Clear controls
    /// render on the deterministic DEBUG fleet and are UI-testable.
    /// Env knob `HERMES_FLEET_AVATAR_UNSUPPORTED=1` scripts the honest
    /// unsupported state (the editor hides the upload controls).
    func supportsAvatarUpload(_ profile: String) async -> Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_AVATAR_UNSUPPORTED"] != "1"
    }

    /// Portrait generation is available on the scripted fleet; the
    /// preview/confirm staging journey is deterministic.
    func supportsPortraitGeneration() async -> Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_AVATAR_UNSUPPORTED"] != "1"
    }

    /// Deterministic generated-portrait fixture: a valid decodable PNG
    /// (the editor normalizes + stages it through the SAME path a real
    /// gateway portrait takes — never a local avatar authority).
    func generatePortrait(prompt: String) async throws -> Data {
        guard await supportsPortraitGeneration() else { throw BotPortraitError.unavailable }
        return ScriptedPetPNG.magenta
    }

    // MARK: #9 — scripted pet surface (pet.gallery / pet.thumb)

    /// Scripted Petdex rows per gateway. The SAME slug deliberately maps
    /// to different thumbnails per gateway (route-provenance proof: the
    /// cache and every request key on GatewayID + ProfileSlug + PetSlug).
    private static let petThumbnails: [String: [String: Data]] = [
        "workstation": [
            "spark-fox": ScriptedPetPNG.magenta,
            "pixel-owl": ScriptedPetPNG.green,
            "null-cat": ScriptedPetPNG.magenta,
        ],
        "render-box": [
            // Same three slugs, DIFFERENT images on this gateway.
            "spark-fox": ScriptedPetPNG.green,
            "pixel-owl": ScriptedPetPNG.magenta,
            "null-cat": ScriptedPetPNG.green,
        ],
    ]

    private func scriptedPets(for gatewayID: GatewayID, localOnly: Bool) -> [HermesPet] {
        let thumbs = Self.petThumbnails[gatewayID.rawValue] ?? [:]
        let rows: [HermesPet] = [
            HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                      curated: false, generated: false, spritesheetURL: nil),
            HermesPet(slug: "pixel-owl", displayName: "Pixel Owl", installed: false,
                      curated: true, generated: false,
                      spritesheetURL: "https://petdex.dev/sheets/pixel-owl.png"),
            HermesPet(slug: "null-cat", displayName: "Null Cat", installed: true,
                      curated: false, generated: true, spritesheetURL: nil),
        ]
        // Two-stage: localOnly returns installed/generated pets only.
        return localOnly ? rows.filter { thumbs[$0.slug] != nil && $0.installed } : rows
    }

    func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery {
        // petsUnsupported gate for the unavailable-state UI journey.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_PETS_UNSUPPORTED"] == "1" {
            throw BotPetError.petsUnavailable("Hermes Pets are not available on this gateway.")
        }
        if ProcessInfo.processInfo.environment["HERMES_FLEET_PETS_FAIL"] == "1" {
            throw BotModeProfileError.rpcFailed("transient fixture failure")
        }
        return HermesPetGallery(
            pets: scriptedPets(for: gatewayID, localOnly: localOnly),
            displayEnabled: true,
            activeSlug: "spark-fox")
    }

    func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data {
        guard let bytes = Self.petThumbnails[gatewayID.rawValue]?[slug] else {
            throw BotPetError.thumbnailUnavailable(slug: slug)
        }
        return bytes
    }

    /// Scripted roster support: whether an avatar asset exists for this
    /// profile (the `profiles.list has_avatar` equivalent) and the bot
    /// metadata written through the seam (the ui_meta equivalent).
    var hasAvatarByProfile: [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Bool] = [:]
        for profile in metadataByProfile.keys { out[profile] = avatarBytesByProfile[profile] != nil }
        return out
    }

    var metadataSnapshot: [String: BotModeMetadata] {
        lock.lock(); defer { lock.unlock() }
        return metadataByProfile
    }

    func loadSectionRegistry() async throws -> (sections: [BotSection], revision: Int?) {
        currentSections()
    }

    func writeSectionRegistry(
        value: MetadataValue, expectedRevision: Int?
    ) async throws -> MetadataWriteReceiptLike {
        let result = applySections(value, expectedRevision: expectedRevision)
        guard result.applied else {
            throw BotSectionSyncError.conflict(
                "expected revision \(expectedRevision ?? 0) but the gateway has \(result.currentRevision)")
        }
        return MetadataWriteReceiptLike(
            applied: true,
            newRevisions: [BotSectionRegistry.metaKey: result.newRevision])
    }

    // Sync lock helpers (NSLock is unavailable from async contexts).

    /// Push the current metadata + asset state into the shared store so
    /// the scripted roster reflects appearance writes on refresh (#7).
    /// Sync (lock-scoped) per the file's async-safe locking discipline.
    private func recordAppearanceWrite(_ profile: String) {
        lock.lock()
        let metadata = metadataByProfile[profile] ?? BotModeMetadata()
        let hasAvatar = avatarBytesByProfile[profile] != nil
        lock.unlock()
        ScriptedBotProfileSeamStore.shared.recordAppearance(
            gatewayID: gatewayID, profile: profile,
            metadata: metadata, hasAvatar: hasAvatar)
    }

    /// Sync lock-scoped avatar asset helpers (NSLock is unavailable from
    /// async contexts).
    private func storeAvatarBytes(_ profile: String, dataURL: String) {
        lock.lock(); defer { lock.unlock() }
        guard let range = dataURL.range(of: "base64,"),
              let data = Data(base64Encoded: String(dataURL[range.upperBound...])) else { return }
        avatarBytesByProfile[profile] = data
    }

    private func dropAvatarBytes(_ profile: String) {
        lock.lock(); defer { lock.unlock() }
        avatarBytesByProfile[profile] = nil
    }

    private func currentAvatarBytes(_ profile: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return avatarBytesByProfile[profile]
    }

    /// CAS-apply bot metadata; returns (currentRevision, applied).
    private func applyMetadata(
        _ profile: String, metadata: BotModeMetadata, expected: Int?
    ) -> (Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        let current = revisionByProfile[profile] ?? 0
        if let expected, expected != current {
            return (current, false)
        }
        metadataByProfile[profile] = metadata
        revisionByProfile[profile] = current + 1
        return (current + 1, true)
    }

    private func seedProfile(_ profile: String, metadata: BotModeMetadata) {
        lock.lock(); defer { lock.unlock() }
        metadataByProfile[profile] = metadata
        revisionByProfile[profile] = 1
        ScriptedBotProfileSeamStore.shared.record(gatewayID: gatewayID, name: profile, title: metadata.title)
    }

    private func currentSections() -> (sections: [BotSection], revision: Int?) {
        lock.lock(); defer { lock.unlock() }
        return (sections, sectionsRevision)
    }

    /// CAS-apply the section registry; returns (applied, current, new).
    private func applySections(
        _ value: MetadataValue, expectedRevision: Int?
    ) -> (applied: Bool, currentRevision: Int, newRevision: Int) {
        lock.lock(); defer { lock.unlock() }
        if let expected = expectedRevision, expected != sectionsRevision {
            return (false, sectionsRevision, sectionsRevision)
        }
        sections = BotSectionRegistry.normalize(value)
        sectionsRevision += 1
        return (true, sectionsRevision, sectionsRevision)
    }
}

/// Slice 2: scripted room source — one hosted room + one legacy room on the
/// workstation fixture so both provenances render with distinct identities.
/// Slice 4: the hosted room is INTERACTIVE (backed by `ScriptedRoomEngine`)
/// so create/open/message/rename/disband/stop/retry/approve are walkable
/// deterministically in the simulator + UI tests. The legacy room stays
/// observational (addendum).
struct ScriptedRoomSource: FleetRoomSourceProviding {
    let gatewayID: GatewayID

    func rooms() async -> [FleetRoom] {
        guard gatewayID.rawValue == "workstation" else { return [] }
        var rooms: [FleetRoom] = [await ScriptedRoomEngine.shared.hostedRoom(gatewayID: gatewayID)]
        rooms += await ScriptedRoomEngine.shared.createdRoomRows(gatewayID: gatewayID)
        if await ScriptedRoomEngine.shared.legacyRoomVisible {
            rooms.append(legacyRoom(gatewayID: gatewayID))
        }
        return rooms
    }

    /// F1: the workstation fixture mirrors a real gateway's
    /// `groups.capabilities` probe (driver + groups.create advertised);
    /// other scripted gateways fail closed (.unknown).
    func createRoomCapability() async -> GroupsCreateCapability {
        guard gatewayID.rawValue == "workstation" else { return .unknown }
        return .supported
    }

    private func legacyRoom(gatewayID: GatewayID) -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(provenance: .desktopLegacy, gatewayID: gatewayID, key: "name:Research Crew"),
            name: "Research Crew",
            members: [FleetRoomMember(name: "Researcher")],
            recentLog: [
                FleetRoomMessage(
                    id: "l1",
                    from: .init(kind: .member, name: "Researcher"),
                    text: "Older room managed from Desktop.",
                    at: 1_757_100_000_000),
            ]
        )
    }
}

/// Slice 4 scripted engine: an in-memory hosted room faithful to the
/// gateway's groups.* semantics (durable log by seq, idempotent send,
/// tombstoned disband, stop/retry/approve counters) — deterministic UI-test
/// fixture, DEBUG simulator only. Env knobs (UI tests):
/// - `HERMES_FLEET_ROOM_FAILURE=1` — the room's transcript carries a typed
///   `turn.failed` (provider_auth_or_access) + a pending retry action.
/// - `HERMES_FLEET_ROOM_APPROVAL=1` — a needs-you approval is pending.
actor ScriptedRoomEngine: RoomChatCommanding, RoomDriverStatusProviding {
    static let shared = ScriptedRoomEngine()

    private var _events: [HostedRoomEventValue] = []
    private var _seq = 0
    private var _roomName = "Launch Crew"
    private var _disbanded = false
    private var _legacyRoomVisible = true
    private var _createdRooms: [String] = []
    private var _sendCount = 0
    private var _renameCount = 0
    private var _stopCount = 0
    private var _retryCount = 0
    private var _approveChoices: [String] = []
    private var _pendingApproval: RoomPendingApproval?
    private var _pendingRetry: RoomPendingRetry?
    private var _lastCreatedMembers: [[String: String]] = []
    private var _createdRoomNames: [String: String] = [:]

    private init() {
        let seed = Self.makeSeed()
        _events = seed.events
        _seq = seed.seq
        _pendingRetry = seed.pendingRetry
        _pendingApproval = seed.pendingApproval
    }

    /// Pure seed builder (callable from nonisolated init AND isolated reset).
    private static func makeSeed()
        -> (events: [HostedRoomEventValue], seq: Int,
            pendingApproval: RoomPendingApproval?, pendingRetry: RoomPendingRetry?) {
        var events: [HostedRoomEventValue] = []
        var seq = 0
        func append(
            kind: String, actorKind: String, actorID: String, actorProfile: String? = nil,
            text: String?, reason: String? = nil
        ) {
            seq += 1
            events.append(HostedRoomEventValue(
                roomID: "room-alpha", seq: seq, eventID: "se-\(seq)", kind: kind,
                actorKind: actorKind, actorID: actorID, actorProfile: actorProfile,
                payloadText: text, reasonCode: reason, createdAt: Date().timeIntervalSince1970))
        }
        append(kind: "room.created", actorKind: "system", actorID: "system", text: nil)
        append(kind: "message.member", actorKind: "member", actorID: "researcher",
               actorProfile: "researcher", text: "Draft is ready for review.")
        var pendingRetry: RoomPendingRetry?
        var pendingApproval: RoomPendingApproval?
        let env = ProcessInfo.processInfo.environment
        if env["HERMES_FLEET_ROOM_FAILURE"] == "1" {
            append(kind: "turn.failed", actorKind: "gateway", actorID: "gateway",
                   actorProfile: "researcher",
                   text: "Provider rejected the request (auth).",
                   reason: "provider_auth_or_access")
            pendingRetry = RoomPendingRetry(taskID: "task-fail-1")
        }
        if env["HERMES_FLEET_ROOM_APPROVAL"] == "1" {
            pendingApproval = RoomPendingApproval(
                memberID: "researcher", taskID: "task-appr-1", executionGeneration: 2,
                requestID: "req-1",
                approval: ["prompt": .string("Allow the researcher to run the web tool?")])
        }
        return (events, seq, pendingApproval, pendingRetry)
    }

    /// Full reset to the deterministic seed (per-test isolation).
    func reset() {
        _roomName = "Launch Crew"
        _disbanded = false
        _legacyRoomVisible = true
        _createdRooms = []
        _sendCount = 0
        _renameCount = 0
        _stopCount = 0
        _retryCount = 0
        _approveChoices = []
        _lastCreatedMembers = []
        let seed = Self.makeSeed()
        _events = seed.events
        _seq = seed.seq
        _pendingApproval = seed.pendingApproval
        _pendingRetry = seed.pendingRetry
    }

    var roomKey: String { "room-alpha" }
    var roomNameValue: String { _roomName }
    var isDisbanded: Bool { _disbanded }
    var legacyRoomVisible: Bool { _legacyRoomVisible }
    var sendCount: Int { _sendCount }
    var stopCount: Int { _stopCount }
    var retryCount: Int { _retryCount }
    var renameCount: Int { _renameCount }
    var approveChoices: [String] { _approveChoices }
    var createdRoomIDs: [String] { _createdRooms }
    var lastCreatedMembers: [[String: String]] { _lastCreatedMembers }

    /// Seed a legacy same-name room (distinctness fixture) on/off.
    func setLegacyRoomVisible(_ visible: Bool) {
        _legacyRoomVisible = visible
    }

    func hostedRoom(gatewayID: GatewayID) -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: roomKey),
            name: _roomName,
            members: [
                FleetRoomMember(name: "Researcher", handle: "researcher"),
                FleetRoomMember(name: "Default", handle: "default"),
            ],
            hosted: HostedRoomState(
                authorityGatewayID: gatewayID.rawValue,
                authorityEpoch: 1,
                latestSeq: _seq,
                advertisedMethods: [
                    "groups.create", "groups.send", "groups.rename", "groups.log",
                    "groups.disband", "groups.stop", "groups.retry", "groups.approve",
                ],
                driverAvailable: !_disbanded))
    }

    @discardableResult
    private func append(
        kind: String, actorKind: String, actorID: String, actorProfile: String? = nil,
        text: String?, reason: String? = nil
    ) -> HostedRoomEventValue {
        _seq += 1
        let event = HostedRoomEventValue(
            roomID: roomKey, seq: _seq, eventID: "se-\(_seq)", kind: kind,
            actorKind: actorKind, actorID: actorID, actorProfile: actorProfile,
            payloadText: text, reasonCode: reason, createdAt: Date().timeIntervalSince1970)
        _events.append(event)
        return event
    }

    // MARK: RoomChatCommanding

    func replay(roomID: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPageSlice {
        let window = _events.filter { $0.roomID == roomID && $0.seq > sinceSeq }
        return RoomLogPageSlice(
            events: Array(window.prefix(limit)),
            cursor: _seq,
            latestSeq: _seq,
            hasMore: window.count > limit,
            authorityGatewayID: "workstation",
            authorityEpoch: 1)
    }

    func send(roomID: String, text: String, threadID: String?) async throws -> Int {
        _sendCount += 1
        append(kind: "message.user", actorKind: "user", actorID: "desktop", text: text)
        return _seq
    }

    func rename(roomID: String, name: String) async throws {
        _renameCount += 1
        _roomName = name
        append(kind: "room.renamed", actorKind: "system", actorID: "system", text: name)
    }

    func disband(roomID: String) async throws {
        _disbanded = true
        append(kind: "room.disbanded", actorKind: "system", actorID: "system", text: nil)
    }

    func stop(roomID: String) async throws -> Int {
        _stopCount += 1
        append(kind: "room.stop_requested", actorKind: "gateway", actorID: "gateway", text: nil)
        return 1
    }

    func retry(roomID: String, taskID: String) async throws {
        _retryCount += 1
        _pendingRetry = nil
    }

    func approve(roomID: String, action: RoomPendingApproval, choice: String) async throws {
        _approveChoices.append(choice)
        _pendingApproval = nil
    }

    func createRoom(name: String, members: [[String: String]]) async throws -> String {
        let roomID = "room-\(_createdRooms.count + 1)"
        _createdRooms.append(roomID)
        _createdRoomNames[roomID] = name
        _lastCreatedMembers = members
        append(kind: "room.created", actorKind: "system", actorID: "system", text: nil)
        return roomID
    }

    /// FleetRoom rows for created rooms (fresh log per room; frozen roster
    /// from the wire members).
    func createdRoomRows(gatewayID: GatewayID) -> [FleetRoom] {
        _createdRooms.map { roomID in
            FleetRoom(
                id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: roomID),
                name: _createdRoomNames[roomID] ?? roomID,
                members: [],
                hosted: HostedRoomState(
                    authorityGatewayID: gatewayID.rawValue,
                    authorityEpoch: 1,
                    advertisedMethods: [
                        "groups.create", "groups.send", "groups.rename", "groups.log",
                        "groups.disband", "groups.stop", "groups.retry", "groups.approve",
                    ],
                    driverAvailable: true))
        }
    }

    // MARK: RoomDriverStatusProviding

    func driverStatus(roomID: String) async throws -> RoomDriverStatus? {
        RoomDriverStatus(
            working: false,
            blocked: _pendingApproval != nil || _pendingRetry != nil,
            counts: [:],
            pendingRetries: _pendingRetry.map { [$0] } ?? [],
            pendingApprovals: _pendingApproval.map { [$0] } ?? [])
    }
}

/// Slice 5 (D19): scripted RoomLink engine (DEBUG simulator only) — a
/// deterministic `RoomLinkCommanding` faithful to the gateway's peer.*
/// semantics. Env knobs (UI tests):
/// - `HERMES_FLEET_ROOMLINK=unsupported` — the gateway reports RoomLink
///   disabled with reason `durable_run_storage_required` (honest unsupported
///   state; no grant is ever minted).
/// - `HERMES_FLEET_ROOMLINK=stale` — the replica starts BEHIND (lastSeq 4 of
///   latestSeq 10) so promotion is blocked until Replay now runs.
/// - default — supported direct/TLS catalog, caught-up replica.
actor ScriptedRoomLinkEngine: RoomLinkCommanding {
    static let shared = ScriptedRoomLinkEngine()

    private var mode: Mode {
        switch ProcessInfo.processInfo.environment["HERMES_FLEET_ROOMLINK"] {
        case "unsupported": return .unsupported
        case "stale": return .staleReplica
        default: return .supported
        }
    }

    private enum Mode {
        case supported
        case unsupported
        case staleReplica
    }

    private var _inviteCount = 0
    private var _revokeCount = 0
    private var _registerCount = 0
    private var _promoteConfirms: [Bool] = []
    private var _replicateCount = 0
    private var _replicaCaughtUp: Bool

    private init() {
        _replicaCaughtUp = ProcessInfo.processInfo.environment["HERMES_FLEET_ROOMLINK"] != "stale"
    }

    var inviteCount: Int { _inviteCount }
    var revokeCount: Int { _revokeCount }
    var registerCount: Int { _registerCount }
    var promoteConfirms: [Bool] { _promoteConfirms }
    var replicateCount: Int { _replicateCount }

    func reset() {
        _inviteCount = 0
        _revokeCount = 0
        _registerCount = 0
        _promoteConfirms = []
        _replicateCount = 0
        _replicaCaughtUp = mode != .staleReplica
    }

    private var supportedNegotiation: RoomLinkNegotiation {
        RoomLinkNegotiation(
            authorityGatewayID: "install:workstation",
            enabled: true,
            profile: "default",
            protocolVersions: [2],
            installationID: "workstation",
            linkModes: ["direct"],
            persistentProcess: true,
            textOnly: true,
            attachmentsSupported: false,
            catalogDigest: String(repeating: "c", count: 64),
            executionPolicy: RoomLinkExecutionPolicy(
                version: 1, targetProfile: "default",
                enabledToolsets: ["bot_room"], approvalMode: "manual",
                maxIterations: 12, policyDigest: String(repeating: "p", count: 64)),
            endpoint: RoomLinkEndpoint(
                available: true,
                url: "https://roomlink.fixture.test/v1",
                transportSecurity: "tls"),
            methods: [
                "groups.capabilities", "groups.peer.invite", "groups.peer.register",
                "groups.peer.revoke", "groups.replica_state", "groups.replicate",
                "groups.promote", "groups.demote",
            ])
    }

    // MARK: RoomLinkCommanding

    func negotiate() async throws -> RoomLinkNegotiation {
        switch mode {
        case .supported, .staleReplica:
            return supportedNegotiation
        case .unsupported:
            return RoomLinkNegotiation(
                authorityGatewayID: "install:workstation",
                enabled: false,
                disabledReason: .durableRunStorageRequired)
        }
    }

    func invite(
        roomID: String?, memberID: String?, ttlSeconds: Double
    ) async throws -> RoomLinkGrant {
        guard mode != .unsupported else {
            throw RoomCommandFailure.unsupportedMethod("groups.peer.invite")
        }
        _inviteCount += 1
        let now = Date()
        return RoomLinkGrant(
            id: "grant-\(_inviteCount)",
            token: "fixture-grant-\(_inviteCount)-0123456789abcdef",
            roomID: roomID,
            memberID: memberID ?? "researcher",
            targetProfile: "researcher",
            permissions: RoomLinkGrant.Permission.allCases,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttlSeconds))
    }

    func registerPeer(
        roomID: String, memberID: String, grant: RoomLinkGrant,
        targetURL: String
    ) async throws -> RoomPeerRoute {
        _registerCount += 1
        return RoomPeerRoute(
            roomID: roomID, memberID: memberID,
            targetInstallID: "install:remote", targetProfile: grant.targetProfile,
            mode: "direct", transportSecurity: "tls", status: .ready)
    }

    func revoke(grant: RoomLinkGrant) async throws {
        _revokeCount += 1
    }

    func peerRoutes(roomID: String) async throws -> [RoomPeerRoute] {
        guard mode != .unsupported else { return [] }
        return [RoomPeerRoute(
            roomID: roomID, memberID: "researcher",
            targetInstallID: "install:remote", targetProfile: "researcher",
            mode: "direct", transportSecurity: "tls", status: .ready)]
    }

    func replicaState(roomID: String) async throws -> RoomReplicaState? {
        guard mode != .unsupported else { return nil }
        // Replica of a FOREIGN authority ("install:hub") — the only state
        // upstream promote_replica allows promoting. Authority == local
        // would be an honest "already holds the room authority" refusal.
        return RoomReplicaState(
            roomID: roomID, name: "Launch Crew",
            authorityGatewayID: "install:hub", authorityEpoch: 3,
            lastSeq: _replicaCaughtUp ? 10 : 4,
            latestSeq: 10,
            eventBytes: 4096, createdAt: 1, updatedAt: 2)
    }

    func roomReplaySource(roomID: String) async throws -> any RoomReplaySourceProviding {
        ScriptedRoomReplaySource()
    }

    func replicateSink() async throws -> any RoomReplicateSink {
        self
    }

    func promote(roomID: String, confirm: Bool) async throws -> RoomPromotionReceipt {
        _promoteConfirms.append(confirm)
        guard confirm else {
            throw RoomCommandFailure.confirmRequired(
                "promotion requires confirm=true acknowledging the previous authority can no longer commit")
        }
        guard _replicaCaughtUp else {
            throw RoomCommandFailure.rpcFailed("replica is behind the authority log", 0)
        }
        // Upstream promote_replica shape: THIS gateway ("install:workstation")
        // becomes the authority at epoch+1; the foreign authority it took
        // over ("install:hub") is named as previous — consistent with
        // replicaState above.
        return RoomPromotionReceipt(
            roomID: roomID,
            authorityGatewayID: "install:workstation", authorityEpoch: 4,
            previousGatewayID: "install:hub", previousEpoch: 3,
            claimSeq: 11, latestSeq: 10)
    }

    func demote(roomID: String, observedGatewayID: String, observedEpoch: Int) async throws {}
}

/// Scripted authority replay surface: real-shaped `groups.state` room row +
/// one caught-up `groups.log` page (mirrors upstream shapes deterministically
/// for the DEBUG simulator + UI tests).
private struct ScriptedRoomReplaySource: RoomReplaySourceProviding {
    func roomProfile(roomID: String) async throws -> RoomReplayProfile {
        RoomReplayProfile(
            roomID: roomID,
            name: "Launch Crew",
            members: .array([
                .object(["member_id": .string("researcher"), "profile": .string("researcher")]),
                .object(["member_id": .string("fleet"), "profile": .string("default")]),
            ]),
            authorityGatewayID: "install:hub",
            authorityEpoch: 3)
    }

    func logPage(roomID: String, sinceSeq: Int) async throws -> RoomReplayLogPage {
        RoomReplayLogPage(
            roomID: roomID,
            page: .object([
                "events": .array([]),
                "cursor": .number(10),
                "latest_seq": .number(10),
                "has_more": .bool(false),
                "authority": .object([
                    "gateway_id": .string("install:hub"),
                    "epoch": .number(3)]),
            ]),
            cursor: 10,
            latestSeq: 10,
            hasMore: false,
            authorityGatewayID: "install:hub",
            authorityEpoch: 3)
    }
}

extension ScriptedRoomLinkEngine: RoomReplicateSink {
    func replicate(
        roomID: String, roomName: String, members: MetadataValue, page: MetadataValue
    ) async throws -> RoomReplicateReceipt {
        _replicateCount += 1
        _replicaCaughtUp = true
        return RoomReplicateReceipt(
            roomID: roomID, storedSeq: 10, ingested: 6,
            authorityGatewayID: "install:hub", authorityEpoch: 3,
            caughtUp: true)
    }
}

#endif

// MARK: - Simple mode: scripted Bot Desktop (DEBUG simulator only)

/// Deterministic Bot Desktop for the simulator: a synthetic RFB server
/// stream (3.8 / None / 320x200 fixture frame) and an in-memory lease. Never
/// a stand-in for a live gateway; it exists so the Simple-mode browser card
/// and takeover viewer are walkable in UI tests.
final class ScriptedBotDisplay: BotDisplayProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var holder: (DisplayLeaseHolder, String?) = (.agent, nil)
    private var epoch = 0
    private var minted = 0

    private func lease() -> DisplayLease {
        lock.lock(); defer { lock.unlock() }
        return DisplayLease(holder: holder.0, viewerHash: holder.1.map(BotDisplayViewerHash.hash), epoch: epoch)
    }

    private func snapshot() -> DisplayStatusSnapshot {
        DisplayStatusSnapshot(supported: true, installed: true, running: true,
                              geometry: "320x200", browser: "chromium", lease: lease())
    }

    func status(profile: String?) async throws -> DisplayStatusSnapshot { snapshot() }

    func thumbnail(profile: String?) async throws -> DisplayThumbnail {
        if lease().holder == .human { return DisplayThumbnail(imageData: nil, suppressed: "human") }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 14))
        }
        return DisplayThumbnail(imageData: image.jpegData(compressionQuality: 0.7), suppressed: nil)
    }

    func observe(profile: String?, viewerID: String?) async throws -> DisplayObservation {
        let id: String = {
            lock.lock(); defer { lock.unlock() }
            if let viewerID { return viewerID }
            minted += 1
            return "scripted-viewer-\(minted)"
        }()
        return DisplayObservation(ticket: "scripted-ticket", path: "/api/display/ws", viewerID: id, status: snapshot())
    }

    func acquireLease(profile: String?, viewerID: String, reason: String?) async throws -> DisplayLease {
        lock.withLock { holder = (.human, viewerID); epoch += 1 }
        return lease()
    }

    func releaseLease(profile: String?, viewerID: String) async throws -> DisplayLease {
        lock.withLock { holder = (.agent, nil); epoch += 1 }
        return lease()
    }

    func openStream(_ observation: DisplayObservation) async throws -> any DisplayByteStream {
        ScriptedRFBStream()
    }
}

private final class ScriptedRFBStream: DisplayByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]
    private var closed = false

    init() {
        let w = 320, h = 200
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if y < 24 { px[i] = 240; px[i + 1] = 240; px[i + 2] = 240 }          // address bar
                else { px[i] = 200; px[i + 1] = 140; px[i + 2] = UInt8(40 + x / 4) } // page
            }
        }
        chunks = [
            RFBServerFixture.version,
            RFBServerFixture.securityTypes([1]) + RFBServerFixture.securityResultOK(),
            RFBServerFixture.serverInit(width: w, height: h, name: "scripted-bot-desktop"),
            RFBServerFixture.framebufferUpdate([.raw(x: 0, y: 0, width: w, height: h, bgrx: px)]),
            RFBServerFixture.framebufferUpdate([.copy(x: 0, y: 100, width: 160, height: 24, sourceX: 0, sourceY: 0)]),
        ]
    }

    func send(_ data: Data) async throws {}

    func receive() async throws -> Data {
        while true {
            let next: Data? = {
                lock.lock(); defer { lock.unlock() }
                if closed { return nil }
                return chunks.isEmpty ? Data() : chunks.removeFirst()
            }()
            guard let next else { throw BotDisplayError.streamClosed(code: 1000) }
            if !next.isEmpty { return next }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func close() async {
        lock.withLock { closed = true }
    }
}
