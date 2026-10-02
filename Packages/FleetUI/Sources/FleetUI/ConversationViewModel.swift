import Foundation
import Observation
import FleetCore

/// One rendered row in the conversation transcript (U3).
///
/// Pure presentation value derived from `SessionMessage` (persisted/cold-start
/// history) and `ConversationEvent` (streamed turns). `isStreaming` marks an
/// assistant row still accumulating `message.delta` frames; `isFailed` marks a
/// turn whose `message.complete` reported `status == "error"`.
public struct ConversationRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user
        case assistant
        case tool
        case status
        case system
        case error
    }

    /// Stable identity for SwiftUI list rendering: the durable `row_id` when
    /// one exists, else a monotonic client-assigned id. Never content-derived.
    public let id: String
    public var kind: Kind
    public var text: String
    /// Secondary detail (tool name/context, status kind, thinking text).
    public var detail: String?
    /// Display-only authoring time (Unix seconds) carried through from the
    /// persisted/streamed `SessionMessage` when the gateway stamped one
    /// (U6: timestamp styling under the bubbles). Nil for live rows the
    /// gateway has not stamped yet — no time is fabricated.
    public var timestamp: Double?
    public var isStreaming: Bool
    public var isFailed: Bool
    /// R10-T2: the durable gateway `row_id` this row was decoded from, when
    /// present — the reaction write target. Live rows (streamed this
    /// session) carry nil and react via `newest_role`.
    public var rowID: String?
    /// R10-T2: reactions rendered under this bubble (a live view over the
    /// VM's `reactionsByRowID`, updated by the view). Nil = none.
    public var reactions: [MessageReaction]?

    public init(
        id: String,
        kind: Kind,
        text: String,
        detail: String? = nil,
        timestamp: Double? = nil,
        isStreaming: Bool = false,
        isFailed: Bool = false,
        rowID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isFailed = isFailed
        self.rowID = rowID
    }

    // MARK: VoiceOver semantics (P2-7)

    /// A11y label identifying who produced this row + its content. Gives
    /// assistive-tech users the speaker (User / Assistant / Tool / Status /
    /// System / Error) that the combined bubble otherwise hides. Content is
    /// omitted when empty (e.g. an assistant row still streaming its first
    /// delta), so VoiceOver never announces a bare dangling comma.
    public var accessibilityLabel: String {
        let speaker: String
        let content: String
        switch kind {
        case .user:
            speaker = "User"
            content = text
        case .assistant:
            speaker = "Assistant"
            content = text
        case .tool:
            speaker = "Tool"
            // Tool rows carry the tool name as `text` and context as `detail`.
            content = [text, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        case .status:
            speaker = "Status"
            content = text
        case .system:
            speaker = "System"
            content = text
        case .error:
            speaker = "Error"
            content = text
        }
        return content.isEmpty ? speaker : speaker + ", " + content
    }

    /// A11y value describing live row state: "Streaming" while a turn is still
    /// accumulating, "Failed" for an errored turn, otherwise "".
    public var accessibilityValue: String {
        if isFailed { return "Failed" }
        if isStreaming { return "Streaming" }
        return ""
    }
}

/// The conversation screen view model (U3) — observable so SwiftUI renders the
/// full loop: open/create a session (session.create/resume), submit prompts
/// (prompt.submit), render streamed events incrementally (M5), complete a turn
/// (message.complete), interrupt; on reconnect show replay hydration (M6
/// replay-hold → flush seq-gated) and re-auth UX on 4401 (M11: no silent
/// retry). Persisted history via `CacheStoring` (M10) for cold-start.
///
/// FleetUI depends ONLY on the FleetCore seams (`ConversationSessionProviding`,
/// `CacheStoring`) — never on the transport module (M0 guard). The concrete
/// bundle is injected by the composition root.
@MainActor
@Observable
public final class ConversationViewModel {
    /// The conversation screen phase — drives the banner/composer states.
    public enum Phase: Equatable, Sendable {
        /// No work started.
        case idle
        /// Connecting the gateway socket.
        case connecting
        /// session.create / session.resume in flight.
        case opening
        /// Ready to accept a prompt (turn idle or completed).
        case ready
        /// A turn is streaming (message.start → deltas → message.complete).
        case streaming
        /// The socket dropped mid-stream / mid-session; awaiting a reconnect.
        case disconnected
        /// Reconnect + replay hydration in flight.
        case reconnecting
        /// 4401 — authentication required; re-auth is EXPLICIT (no silent
        /// retry, M11).
        case authRequired
        /// A classified failure (non-secret description).
        case failed(String)
    }

    // MARK: Injected seams (composition root)

    private let session: any ConversationSessionProviding
    private let cache: any CacheStoring
    public let route: Route
    /// The runtime session id to resume, or nil to create a new conversation.
    public let sessionID: String?
    /// R9-T1/T2/T3 — biometric seam for the approval gate (FaceID-gated
    /// approve, confirmed YOLO enable). Injected by the composition root;
    /// defaults to the app-lock provider's seam.
    private let biometrics: any AppLockBiometricAuth

    // MARK: Observable state (SwiftUI renders these)

    public private(set) var phase: Phase = .idle
    /// The DISPLAY window the view renders — capped at `maxDisplayRows` so a
    /// long-lived session never grows the in-memory array unboundedly (P2-8).
    /// The authoritative, full history lives in `allRows` (and the persisted
    /// cache), so capping the window never loses history.
    public var transcript: [ConversationRow] {
        var rows = Array(allRows.suffix(maxDisplayRows))
        // R10-T2: project the reaction state onto each row for rendering
        // (durable-keyed; a live row reads its in-flight optimistic state
        // under the live-* key).
        for index in rows.indices {
            let key = rows[index].rowID ?? Self.liveRowKey(kind: rows[index].kind)
            rows[index].reactions = reactionsByRowID[key]?.reactions
        }
        return rows
    }
    public private(set) var isStreaming = false
    /// R10-T2: reactions per transcript row id — rendered under the bubbles.
    /// Sources: history-carried `display_metadata.reactions` (durable rows)
    /// and post-`message.react` server truth / optimistic updates.
    public private(set) var reactionsByRowID: [String: MessageReactionsSnapshot] = [:]
    public private(set) var replayNotice: String?
    /// t_8401d3c3 — non-secret stream-integrity notice shown when a gap was
    /// detected on the live event stream (recovered via targeted replay, or
    /// unrecoverable → authoritative history refetch). Never silent loss.
    public private(set) var integrityNotice: String?
    /// Non-secret error / auth surface text.
    public private(set) var errorMessage: String?
    /// Issue #4 — live skill suggestions for the slash composer palette.
    public private(set) var skillSuggestions: [SlashCommandSuggestion] = []
    /// True while a catalog/completion request is in flight.
    public private(set) var isLoadingSkillSuggestions = false
    /// Non-secret discovery/dispatch compatibility or stale-command error.
    /// The composer keeps the text editable while this is shown.
    public private(set) var skillSuggestionError: String?
    /// Whether the composer is currently editing slash-prefixed input. This
    /// remains true for an empty catalog so the palette can honestly render
    /// its "No skills available" state.
    public private(set) var isSlashInputActive = false
    /// Whether the slash palette should render above the input.
    public var isSlashPaletteVisible: Bool {
        isSlashInputActive || isLoadingSkillSuggestions || !skillSuggestions.isEmpty || skillSuggestionError != nil
    }
    /// R9-T1 — the approval banner state (pending request + YOLO readback).
    /// Lazily built once the session opens; nil when the concrete session
    /// exposes no approvals seam (fail-soft feature detection).
    public private(set) var approvalViewModel: ApprovalViewModel?
    /// R9-T2/T3/T4 — the conversation-tooling state (sticky model pick,
    /// live context meter, steer/rename/fork). Lazily built once the
    /// session opens; nil when the concrete session exposes no tooling seam.
    public private(set) var toolingViewModel: ConversationToolingViewModel?
    /// R9-T4 — a successfully forked session awaiting navigation. The view
    /// observes this, replaces the open conversation, and clears it
    /// (`consumeForkedSession()`).
    public private(set) var forkedSession: ConversationSession?
    /// True when the current transcript was hydrated from the persisted cache
    /// (M10 cold-start) rather than a live server fetch.
    public private(set) var hydratedFromCache = false
    /// H1 (t_01c9d411) — true from cold-start of an EXISTING session until
    /// history actually lands (cache rows, the resume projection, or the
    /// authoritative fetch) or an authoritative fetch confirms the session
    /// is empty. While armed and the transcript is still empty, the view
    /// renders the history-loading placeholder instead of a new-chat blank
    /// slate. A FAILED authoritative fetch NEVER clears it via the empty
    /// path — cached rows survive untouched and an honest error surfaces.
    public private(set) var isHistoryHydrationInProgress = false
    /// True when the placeholder should render right now: hydration is in
    /// flight AND no row has landed yet.
    public var showsHistoryLoadingPlaceholder: Bool {
        isHistoryHydrationInProgress && allRows.isEmpty
    }
    /// H1 (t_01c9d411) — non-secret notice shown when the authoritative
    /// history fetch failed. Cached rows (if any) stay rendered; a retry
    /// rides the next reconnect/replay hydration.
    public private(set) var historyLoadError: String?
    /// Best-effort session metadata from session.info.
    public private(set) var sessionTitle: String?
    public private(set) var sessionModel: String?

    // MARK: R10-T1 — attachment staging (composer tray)

    /// The attachment seam — fail-closed `UnsupportedAttachmentStaging` until
    /// the concrete session exposes one (`AttachmentStagingCapable`), so the
    /// composer's attach affordances surface an honest error instead of
    /// pretending the gateway staged the file.
    private let attachments: any AttachmentStagingProviding
    /// Pending attachments staged on the gateway, awaiting the next send.
    /// Identified by a local UUID — STAGING IS NOT IDEMPOTENT on the wire
    /// (every attach call writes a new gateway-side file), so `Task.cancel`
    /// mid-upload is surfaced as an error rather than retried blind.
    public private(set) var pendingAttachments: [PendingAttachment] = []
    /// True while an attachment upload is in flight (chip spinner).
    public private(set) var isUploadingAttachment = false
    /// Non-secret composer attachment error banner text (never silent).
    public private(set) var attachmentError: String?

    // MARK: R10-T2 — message reactions (Tapback)

    /// The reaction seam — fail-closed `UnsupportedReactionProviding` until
    /// the concrete session exposes one (`ReactionCapable`), so the
    /// long-press menu surfaces an honest error instead of pretending.
    private let reactionSeam: any ReactionProviding
    /// Issue #4 slash seam — fail-closed for older/scripted sessions that do
    /// not advertise Hermes' canonical slash RPCs.
    private let slashCommands: any SlashCommandProviding
    /// Non-secret reaction error banner text (never silent).
    public private(set) var reactionError: String?

    // MARK: R10-T4 — voice (client-side STT/TTS, documented deviation)

    /// The voice seam — fail-closed `UnsupportedVoiceTranscriber` when the
    /// composition root wires no engine, so the mic affordances hide entirely
    /// instead of pretending. DEVIATION: hermes-agent 0.21 has NO client-audio
    /// WS upload (`/voice` listens on the GATEWAY's local mic,
    /// `full_duplex_listen` server.py:17334) — iOS transcribes on-device via
    /// the Speech framework and submits TEXT through `prompt.submit`; replies
    /// are spoken locally via AVSpeechSynthesizer. See docs/R10.
    private let voice: any VoiceTranscribing
    /// R10-T5: serializes TTS chunks. Each streaming delta used to spawn its
    /// own unstructured Task, so two chunks could reach the synthesizer OUT
    /// OF ORDER (spoken audio garbled; caught as a gate flake —
    /// speakCalls ["fleet", "Hello "]). An actor queue preserves arrival
    /// order across awaits.
    private let speechQueue = SpeechQueue()
    /// True when a real voice engine is wired (drives affordance visibility).
    public var isVoiceAvailable: Bool {
        if voice is UnsupportedVoiceTranscriber { return false }
        return true
    }
    /// True while mic capture is running (mic button shows stop).
    public private(set) var isListening = false
    /// Honest authorization-denied state for the gate UI (Settings deep link).
    public private(set) var isVoiceDenied = false
    /// The latest transcript, landed for composer REVIEW (review-first).
    public private(set) var latestVoiceTranscript: VoiceTranscript?
    /// Voice mode: assistant replies are spoken (TTS). User-toggled.
    public var isVoiceModeEnabled = false
    /// Optional: auto-submit a FINAL transcript (submit-on-silence).
    /// Default OFF — review-first. A PARTIAL (manual-stop) transcript is
    /// NEVER auto-submitted.
    public var isSubmitOnSilenceEnabled = false
    /// Non-secret voice error banner text (never silent).
    public private(set) var voiceError: String?
    /// The mic capture task. `nonisolated(unsafe)`: only canceled from
    /// `deinit` (the established eventTask/statusWatcher pattern); all
    /// creation/nil-out happens on the main actor.
    nonisolated(unsafe) private var micTask: Task<Void, Never>?

    // MARK: Internal state

    private var openedSessionID: String?
    /// FOS-4: the session id the Continue index may record (the RESOLVED
    /// open — either the resumed exact session or the freshly created one).
    /// Exposed read-only so ConversationView records the open only after
    /// the destination actually resolved (SPEC §17).
    public var resolvedSessionID: String? { openedSessionID ?? sessionID }
    /// t_8401d3c3 — the client's last APPLIED event id for the open session's
    /// stream (the "last event id" of Last-Event-ID semantics). Advances only
    /// when an event is actually rendered into the transcript; sent as
    /// `last_seen` on session.resume (subscribe) and used as the resume
    /// cursor for targeted gap replay. Distinct from the transport watermark
    /// (highest observed): applying is what matters for lossless rendering.
    private var lastAppliedEventID: Int?
    private var rowCounter = 0
    /// P0-8: reasoning/thinking deltas that arrive BEFORE this turn's
    /// `message.start` (live wire order: reasoning streams first). Buffered
    /// here instead of attaching to the PREVIOUS turn's completed assistant
    /// row, and flushed into the row when this turn's assistant row is
    /// created (`message.start`, or the first `message.delta` minting one).
    private var pendingReasoning: String?
    /// R10-T4 TTS: whether any assistant chunk was spoken for the current
    /// turn (guards the exactly-once complete-text fallback).
    private var spokenThisTurn = false
    /// `nonisolated(unsafe)`: the event task is only ever CANCELED from
    /// `deinit` (a nonisolated context); cancel is thread-safe. All mutation
    /// (creation, nil-out) happens on the main actor.
    nonisolated(unsafe) private var eventTask: Task<Void, Never>?
    /// `nonisolated(unsafe)`: same pattern — only canceled in `deinit`.
    nonisolated(unsafe) private var statusWatcher: Task<Void, Never>?
    private var hasStarted = false
    /// Generation of the newest conversation recovery operation
    /// (t_e77c614c). Bumped when `reconnect()` / `reauthenticate()` /
    /// `recoverGap()` starts; an in-flight operation whose captured token no
    /// longer matches is STALE and its completion is dropped (the
    /// `OnboardingViewModel.beginOperation()` fencing pattern).
    @ObservationIgnored private var operationGeneration = 0
    /// Generation fence for live slash completion requests. A slow response
    /// from an older query must never overwrite the newest composer state.
    @ObservationIgnored private var slashSuggestionGeneration = 0
    /// Canceled from `deinit`; all creation and replacement happens on the
    /// main actor while the VM is alive.
    nonisolated(unsafe) private var slashSuggestionTask: Task<Void, Never>?
    /// Status poll cadence (short in tests; production uses the default).
    private let statusInterval: Duration
    /// Authoritative transcript history — unbounded, persisted to the cache
    /// (P2-8). The public `transcript` is a capped display window over this.
    private var allRows: [ConversationRow] = []
    /// Maximum rows kept in the in-memory display window (P2-8 retention
    /// policy). Older rows remain in the persisted authoritative history.
    private let maxDisplayRows: Int

    public init(
        session: any ConversationSessionProviding,
        cache: any CacheStoring,
        route: Route,
        sessionID: String?,
        biometrics: any AppLockBiometricAuth = NeverLockBiometricAuth(),
        statusInterval: Duration = .milliseconds(400),
        maxDisplayRows: Int = 200,
        voice: (any VoiceTranscribing)? = nil
    ) {
        self.session = session
        self.cache = cache
        self.route = route
        self.sessionID = sessionID
        self.biometrics = biometrics
        self.statusInterval = statusInterval
        self.maxDisplayRows = maxDisplayRows
        // R10-T4: fail-closed voice default when no engine is injected.
        self.voice = voice ?? UnsupportedVoiceTranscriber()
        // R10-T1: one cast at build time (the ApprovalsCapable discipline).
        if let capable = session as? AttachmentStagingCapable {
            self.attachments = capable.attachments
        } else {
            self.attachments = UnsupportedAttachmentStaging()
        }
        // R10-T2: same one-cast discipline for the reaction seam.
        if let capable = session as? ReactionCapable {
            self.reactionSeam = capable.reactions
        } else {
            self.reactionSeam = UnsupportedReactionProviding()
        }
        // Issue #4: same one-cast/fail-closed discipline for slash commands.
        if let capable = session as? SlashCommandCapable {
            self.slashCommands = capable.slashCommands
        } else {
            self.slashCommands = UnsupportedSlashCommandProviding()
        }
    }

    /// P2-3: when the VM is permanently released (the conversation screen is
    /// popped for good), stop the one-time event subscription so its task does
    /// not linger holding the session. Temporary disappearances do NOT reach
    /// here — the VM survives push/pop, so the live event stream is retained
    /// (single-subscriber: it cannot be re-created after cancellation).
    deinit {
        eventTask?.cancel()
        statusWatcher?.cancel()
        micTask?.cancel()
        slashSuggestionTask?.cancel()
    }

    // MARK: Lifecycle

    /// Connect → open the session (resume existing or create new) → subscribe
    /// to streamed events → hydrate persisted history for cold-start.
    /// Idempotent: repeated calls while already live are no-ops; a failed
    /// initial open can be retried (P1-5).
    ///
    /// P2-3: one-time init (hasStarted + cold-start hydrate + the event
    /// subscription) is separate from the RESTARTABLE status watcher. The
    /// client's `events` is a single-subscriber `AsyncStream` that cannot be
    /// re-iterated after its consumer is cancelled (verified empirically), so
    /// the event task is created ONCE and kept alive for the VM's lifetime —
    /// `teardown()` never cancels it. A re-appear after a temporary
    /// disappearance therefore only needs to restart the status watcher; the
    /// live event subscription is untouched, so the screen is never left
    /// without monitoring.
    public func start() async {
        if !hasStarted {
            hasStarted = true
            // M10 cold-start: render persisted history immediately while the
            // socket opens, so an offline/relaunch shows the last transcript.
            if let sessionID, transcript.isEmpty {
                // H1 (t_01c9d411): opening an EXISTING chat must never look
                // like a fresh new-chat slate while history is still in
                // flight. Arm the hydration placeholder BEFORE the (possibly
                // empty) cache read; it is cleared only by rows actually
                // landing or by an authoritative empty confirmation — never
                // by a failed fetch (cache rows survive, M10 contract).
                isHistoryHydrationInProgress = true
                await hydrateFromCache(sessionID: sessionID)
            }
        }
        // If a session is already open, this is a re-appear after a temporary
        // disappearance: the connection + session + event subscription are
        // still valid. Restart the RESTARTABLE status watcher (P2-3); do NOT
        // re-create the event task — the stream cannot be re-iterated, and
        // cancelling it would leave the screen permanently unsubscribed.
        if openedSessionID != nil {
            startStatusWatcher()
            return
        }
        guard await connectAndOpen() else { return }
        // Adopt the gateway's replay epoch on first open so a LATER reconnect
        // actually replays (M6: the engine adopts on its first call and
        // replays on the next after a reconnect). Nothing is watermarked yet,
        // so this surfaces no notice on a normal open.
        do {
            let outcomes = try await session.replay.replayAfterReconnect()
            if outcomes.contains(where: { outcome in
                switch outcome {
                case .replayed, .truncated, .epochChanged, .failed: return true
                default: return false
                }
            }) {
                replayNotice = Self.replayNotice(outcomes)
            }
        } catch {
            // Non-fatal: if the first adoption fails (e.g. transient drop
            // during open), the next reconnect will retry it.
        }
    }

    /// Connect the socket, then ensure the session is open and the event +
    /// status subscriptions are live. Returns true only when a session is open
    /// AND subscriptions exist — `.ready` is NEVER set without them (P1-5).
    /// Shared by `start()` (initial open) and `reconnect()`/`reauthenticate()`
    /// (recovery), so an initially-failed-open conversation recovers to a
    /// WORKING composer instead of an enabled-but-dead one.
    private func connectAndOpen() async -> Bool {
        phase = .connecting
        do {
            try await session.connect()
        } catch {
            classifyConnectFailure(error)
            return false
        }
        return await ensureOpenAndSubscribed()
    }

    /// Idempotent open + subscribe: open (create/resume) the session if none
    /// is open, and start the event + status subscriptions. Returns true only
    /// when both are live; on failure classifies and returns false.
    ///
    /// t_e77c614c: when fenced by a recovery operation's token, a superseded
    /// open never applies its session result or flips `.ready` — the newer
    /// operation owns the screen state. `nil` (initial `start()`) fences
    /// nothing, matching the pre-existing behavior.
    private func ensureOpenAndSubscribed(fencedBy token: Int? = nil) async -> Bool {
        if openedSessionID == nil {
            phase = .opening
            do {
                if let sessionID {
                    // t_8401d3c3: declare the client's last applied event id on
                    // every (re)subscribe so the resume point travels with the
                    // subscription itself.
                    let resumed = try await session.conversation.resumeSession(
                        sessionID: sessionID,
                        lastEventID: lastAppliedEventID
                    )
                    guard isCurrent(token) else { return false }
                    openedSessionID = resumed.sessionID
                    applyOpenedSession(resumed)
                } else {
                    // R9-T2: ride the sticky per-device model pick on
                    // session.create — the ONLY wire path for a picker
                    // selection (per-session override,
                    // methods_session.py:50-53). Never config.set.
                    let modelParams = toolingViewModel?.createModelParams
                        ?? (model: nil as String?, provider: nil as String?)
                    let created = try await session.conversation.createSession(
                        title: nil,
                        profile: route.profileSlug.rawValue,
                        model: modelParams.model,
                        provider: modelParams.provider,
                        reasoningEffort: toolingViewModel?.selectedEffort,
                        cols: nil
                    )
                    guard isCurrent(token) else { return false }
                    openedSessionID = created.sessionID
                    applyOpenedSession(created)
                }
            } catch {
                guard isCurrent(token) else { return false }
                classifyOpenFailure(error)
                return false
            }
        }
        startEventSubscription()
        startStatusWatcher()
        // R9-T1 rework: reconnect-restore — after (re)opening + subscribing,
        // pull `approval.pending` so a banner whose push event was missed
        // while detached is restored (fail-soft inside the VM; deduped
        // against any banner that did arrive).
        Task { await approvalViewModel?.restorePendingApprovals() }
        phase = .ready
        return true
    }

    /// t_e77c614c — whether `token` still names the newest operation. A `nil`
    /// token (unfenced caller, e.g. the initial `start()`) is always current.
    private func isCurrent(_ token: Int?) -> Bool {
        guard let token else { return true }
        return token == operationGeneration
    }

    // MARK: Operation fencing (t_e77c614c)

    /// Begins a tracked async recovery operation and returns its generation
    /// token used to fence settlement against newer overlapping operations.
    /// Mirrors `OnboardingViewModel.beginOperation()`.
    private func beginOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    /// Explicit user action: reconnect after a transient drop, then run the M6
    /// replay hydration. The UI calls this from the reconnect banner.
    ///
    /// P1-5: a reconnect after an INITIAL connect/open failure must actually
    /// (re)open the session + (re)start subscriptions before it can be called
    /// ready — never set `.ready` with no session and a dead composer. When a
    /// session IS already open (mid-stream drop), it is left as-is: reconnect
    /// + replay only (the live event/status tasks keep running).
    ///
    /// t_e77c614c: generation-fenced — a superseded recovery (user retapped
    /// reconnect, or re-auth started while a reconnect was in flight) never
    /// settles observable state; its stale completion is silently dropped.
    public func reconnect() async {
        let token = beginOperation()
        phase = .reconnecting
        do {
            try await session.connect()
        } catch {
            guard token == operationGeneration else { return }
            phase = .disconnected
            errorMessage = Self.nonSecret(error)
            return
        }
        if openedSessionID == nil {
            // Initial connect/open failure recovery (P1-5): the session was
            // never opened and subscriptions never started — open + subscribe
            // before the connection can be called ready.
            guard await ensureOpenAndSubscribed(fencedBy: token) else { return }
        }
        await runReplayHydration(fencedBy: token)
        guard token == operationGeneration else { return }
        phase = .ready
    }

    /// Explicit user action after a 4401 close (M11 — NEVER silent retry).
    /// Re-authenticates with a fresh ticket, then replays hydration.
    ///
    /// t_e77c614c: generation-fenced (same semantics as `reconnect()`).
    public func reauthenticate() async {
        let token = beginOperation()
        phase = .reconnecting
        do {
            try await session.reauthenticate()
        } catch {
            guard token == operationGeneration else { return }
            phase = .authRequired
            errorMessage = Self.nonSecret(error)
            return
        }
        if openedSessionID == nil {
            guard await ensureOpenAndSubscribed(fencedBy: token) else { return }
        }
        await runReplayHydration(fencedBy: token)
        guard token == operationGeneration else { return }
        phase = .ready
    }

    /// Submit a prompt. Requires an open session and no in-flight turn.
    /// R10-T1: pending attachments were staged on the gateway at PICK time
    /// (`stageAttachment` — the wire attach calls run before submit, exactly
    /// the gateway's designed order since `image.attach_bytes`/`pdf.attach`
    /// queue onto the session for the NEXT `prompt.submit`,
    /// methods_prompt.py:1163+); submit carries the composed text with the
    /// staged refs appended. Attach-only sends (empty text) are valid.
    /// R10-T4: a NEW user turn cuts any spoken reply first — the client-side
    /// mirror of `mark_speech_interrupted` (server.py:17191: the gateway cuts
    /// its own TTS when a new user turn arrives; here the iOS TTS is local,
    /// so the cut is local too).
    /// Canonical Bot Chat/mention preparation hook supplied by AppEnvironment.
    /// Ordinary chat keeps this behavior; skill dispatch runs the expanded
    /// model-facing text through the same preparation boundary.
    public var prepareBotDraft: ((String, String) -> BotConversationDraft)?
    public private(set) var botDraftNotice: String?

    ///
    /// Issue #4 keeps skill display text separate from the expanded model
    /// payload. The Bool tells the SwiftUI composer whether it may clear the
    /// field: a stale/unknown slash command returns false so the invocation
    /// remains editable for correction.
    @discardableResult
    public func send(_ text: String) async -> Bool {
        if isVoiceModeEnabled {
            await voice.stopSpeaking()
            await speechQueue.drain()
        }
        guard let sid = openedSessionID,
              !isStreaming,
              phase == .ready || phase == .streaming else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty else { return false }

        // A leading slash is a deliberate skill invocation. Never pass it to
        // ordinary prompt.submit: dispatch is the canonical Hermes expansion
        // path, and a failed/stale dispatch must leave the field editable.
        if let invocation = Self.parseSlashInvocation(in: text) {
            do {
                let dispatch = try await slashCommands.dispatchSkill(
                    sessionID: sid,
                    name: invocation.name,
                    argument: invocation.argument)
                skillSuggestionError = nil
                return await sendPrepared(
                    modelText: dispatch.message,
                    displayText: dispatch.display.isEmpty ? trimmed : dispatch.display,
                    sessionID: sid)
            } catch {
                skillSuggestionError = Self.nonSecret(error)
                return false
            }
        }
        if Self.isSlashPrefixed(text) {
            skillSuggestionError = "Enter a skill name after /, or remove / to send ordinary chat."
            return false
        }

        return await sendPrepared(modelText: trimmed, displayText: trimmed, sessionID: sid)
    }

    /// The shared send path for ordinary messages and expanded skill
    /// invocations. Attachments are appended to both representations so the
    /// transcript remains honest while the model receives the staged refs.
    private func sendPrepared(modelText: String, displayText: String, sessionID sid: String) async -> Bool {
        guard !isStreaming,
              phase == .ready || phase == .streaming else { return false }
        let refTexts = pendingAttachments.map(\.refText)
        let prepared = prepareBotDraft?(modelText, sid) ?? BotConversationDraft(text: modelText)
        botDraftNotice = prepared.notice
        let modelPayload = AttachmentStagingRules.promptAppending(refs: refTexts, to: prepared.text)
        // Ordinary chat uses one representation, so Bot Chat draft preparation
        // remains visible exactly as it was before slash support. Skill turns
        // keep Hermes' compact dispatch display separate from the expanded
        // (and possibly bot-prepared) model text.
        let visibleText = modelText == displayText ? prepared.text : displayText
        let displayPayload = AttachmentStagingRules.promptAppending(refs: refTexts, to: visibleText)
        guard !modelPayload.isEmpty else { return false }

        appendRow(.init(id: nextRowID(), kind: .user, text: displayPayload))
        // The refs were staged successfully at pick time — the tray clears
        // with the send (image/PDF bytes are already queued server-side;
        // removing them here would orphan the upload).
        pendingAttachments = []
        do {
            let submission = try await session.conversation.submitPrompt(sessionID: sid, text: modelPayload)
            guard submission.isStreaming else {
                phase = .ready
                return true
            }
        } catch {
            classifyTurnFailure(error)
        }
        return true
    }

    // MARK: Issue #4 — slash discovery/composer state

    /// Update the palette for a composer edit. Bare `/` uses the catalog;
    /// every other slash-prefixed value uses Hermes' live completer.
    /// Requests are canceled and generation-fenced so an older response can
    /// never replace a newer query's results.
    public func updateSlashSuggestions(for text: String) {
        slashSuggestionTask?.cancel()
        slashSuggestionGeneration += 1
        let generation = slashSuggestionGeneration
        guard let slashText = Self.normalizedSlashInput(text) else {
            isSlashInputActive = false
            skillSuggestions = []
            skillSuggestionError = nil
            isLoadingSkillSuggestions = false
            return
        }
        isSlashInputActive = true
        guard let sessionID = openedSessionID else {
            skillSuggestions = []
            skillSuggestionError = nil
            isLoadingSkillSuggestions = false
            return
        }

        skillSuggestions = []
        skillSuggestionError = nil
        isLoadingSkillSuggestions = true
        let provider = slashCommands
        slashSuggestionTask = Task { [weak self] in
            do {
                let suggestions: [SlashCommandSuggestion]
                if slashText == "/" {
                    suggestions = try await provider.skillCatalog(sessionID: sessionID)
                } else {
                    suggestions = try await provider.completeSkills(
                        sessionID: sessionID,
                        text: slashText)
                }
                guard !Task.isCancelled, let self,
                      generation == self.slashSuggestionGeneration else { return }
                self.skillSuggestions = suggestions
                self.isLoadingSkillSuggestions = false
            } catch is CancellationError {
                // A newer keystroke owns the palette state.
            } catch {
                guard !Task.isCancelled, let self,
                      generation == self.slashSuggestionGeneration else { return }
                self.skillSuggestions = []
                self.skillSuggestionError = Self.nonSecret(error)
                self.isLoadingSkillSuggestions = false
            }
        }
    }

    /// Insert a selected canonical skill token while retaining any argument
    /// suffix already typed. The view restores focus after calling this.
    public func selectedSkillText(_ suggestion: SlashCommandSuggestion, replacing text: String) -> String {
        guard suggestion.kind == .skill else { return text }
        let leading = String(text.prefix(while: { $0.isWhitespace }))
        let body = String(text.dropFirst(leading.count))
        guard body.first == "/" else { return text }
        let suffix = body.drop(while: { !$0.isWhitespace })
        return leading + suggestion.text + (suffix.isEmpty ? " " : String(suffix))
    }

    /// Dismiss the slash palette without touching the composer text.
    public func clearSlashSuggestions() {
        slashSuggestionTask?.cancel()
        slashSuggestionGeneration += 1
        skillSuggestions = []
        skillSuggestionError = nil
        isLoadingSkillSuggestions = false
        isSlashInputActive = false
    }

    private struct SlashInvocation {
        let name: String
        let argument: String
    }

    private static func normalizedSlashInput(_ text: String) -> String? {
        let leading = text.drop(while: { $0.isWhitespace })
        guard leading.first == "/" else { return nil }
        return String(leading)
    }

    private static func isSlashPrefixed(_ text: String) -> Bool {
        normalizedSlashInput(text) != nil
    }

    /// Parses only the first command token. The syntactic separator is
    /// removed, while intentional internal/trailing argument whitespace is
    /// preserved, so Hermes receives the user's argument text exactly.
    private static func parseSlashInvocation(in text: String) -> SlashInvocation? {
        guard let normalized = normalizedSlashInput(text), normalized.count > 1 else { return nil }
        let afterSlash = normalized.dropFirst()
        let boundary = afterSlash.firstIndex(where: { $0.isWhitespace })
        let rawName: String
        let argument: String
        if let boundary {
            rawName = String(afterSlash[..<boundary])
            // The whitespace separating the command token from its argument
            // is syntax, not part of `arg`; preserve everything after it.
            argument = String(afterSlash[boundary...].drop(while: { $0.isWhitespace }))
        } else {
            rawName = String(afterSlash)
            argument = ""
        }
        guard !rawName.isEmpty, RoutingGuard.isValidRouteComponent(rawName) else { return nil }
        return SlashInvocation(name: rawName, argument: argument)
    }

    // MARK: R10-T1 — attachment staging (composer tray)

    /// One pending composer attachment: staged on the gateway, awaiting the
    /// next send. `refText` is the cite-form appended to the prompt
    /// (an `@file:` ref for generic files, the gateway's attachment marker
    /// for vision-tile images, a pages summary for PDFs).
    public struct PendingAttachment: Identifiable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let byteCount: Int
        public let refText: String

        public init(id: String, displayName: String, byteCount: Int, refText: String) {
            self.id = id
            self.displayName = displayName
            self.byteCount = byteCount
            self.refText = refText
        }

        /// Chip caption: name + human-readable size.
        public var caption: String {
            "\(displayName) · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
        }
    }

    /// Stage one local file on the gateway now (the "+" pickers call this).
    /// The honest pre-upload guards (10 MB client cap, image-extension
    /// allowlist) fire BEFORE any upload; wire failures surface in the
    /// composer banner, never silently. On success the chip lands in
    /// `pendingAttachments` awaiting the next send.
    public func stageAttachment(name: String, mime: String?, byteCount: Int, loadBytes: @escaping @Sendable () throws -> Data) async {
        guard let sid = openedSessionID else {
            attachmentError = "Attachment needs an open session"
            return
        }
        guard byteCount <= AttachmentStagingRules.clientCapBytes else {
            setAttachmentError(AttachmentStagingError.fileTooLarge(
                name: name, sizeBytes: byteCount, capBytes: AttachmentStagingRules.clientCapBytes))
            return
        }
        guard !isUploadingAttachment else { return } // one upload at a time
        isUploadingAttachment = true
        defer { isUploadingAttachment = false }
        do {
            let bytes = try loadBytes()
            guard bytes.count <= AttachmentStagingRules.clientCapBytes else {
                setAttachmentError(AttachmentStagingError.fileTooLarge(
                    name: name, sizeBytes: bytes.count, capBytes: AttachmentStagingRules.clientCapBytes))
                return
            }
            let safeName = AttachmentStagingRules.sanitizedFilename(name)
            let lower = (safeName as NSString).pathExtension.lowercased()
            let refText: String
            if AttachmentStagingRules.imageExtensions.contains(lower) {
                // Vision-tile path: bytes queue as an attached image the NEXT
                // prompt.submit consumes (server.py `_queue_attached_image`).
                // The prompt cites the gateway's own attachment marker form.
                guard case .success(let dataURL) = AttachmentStagingRules.imageDataURL(filename: safeName, bytes: bytes) else {
                    if case .failure(let error) = AttachmentStagingRules.imageDataURL(filename: safeName, bytes: bytes) {
                        setAttachmentError(error)
                    }
                    return
                }
                let image = try await attachments.attachImageBytes(
                    sessionID: sid, filename: safeName, dataURL: dataURL)
                refText = "[User attached image: \(image.name ?? safeName)]"
            } else if lower == "pdf" {
                guard case .success(let dataURL) = AttachmentStagingRules.pdfDataURL(filename: safeName, bytes: bytes) else {
                    if case .failure(let error) = AttachmentStagingRules.pdfDataURL(filename: safeName, bytes: bytes) {
                        setAttachmentError(error)
                    }
                    return
                }
                let pdf = try await attachments.attachPDF(sessionID: sid, filename: safeName, dataURL: dataURL)
                refText = "[User attached PDF: \(pdf.filename) (\(pdf.pagesAttached) page(s))]"
            } else {
                // Generic artifact: the `@file:` ref the agent's file tools
                // read (file.attach methods_prompt.py:1350).
                let resolvedMime = mime ?? "application/octet-stream"
                guard case .success(let dataURL) = AttachmentStagingRules.fileDataURL(filename: safeName, mime: resolvedMime, bytes: bytes) else {
                    if case .failure(let error) = AttachmentStagingRules.fileDataURL(filename: safeName, mime: resolvedMime, bytes: bytes) {
                        setAttachmentError(error)
                    }
                    return
                }
                let file = try await attachments.attachFile(sessionID: sid, name: safeName, dataURL: dataURL)
                refText = file.refText
            }
            pendingAttachments.append(PendingAttachment(
                id: UUID().uuidString,
                displayName: safeName,
                byteCount: bytes.count,
                refText: refText))
            attachmentError = nil
        } catch let error as AttachmentStagingError {
            setAttachmentError(error)
        } catch is CancellationError {
            setAttachmentError(AttachmentStagingError.rpcFailed("upload cancelled — re-attach the file"))
        } catch {
            setAttachmentError(AttachmentStagingError.rpcFailed(Self.nonSecret(error)))
        }
    }

    /// Remove a pending attachment. Image/PDF bytes are already queued on
    /// the gateway session — the ref simply stops being cited on send (the
    /// harmless residue matches `image.detach` semantics without a second
    /// wire call).
    public func removePendingAttachment(_ id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Dismiss the composer attachment error banner.
    public func clearAttachmentError() {
        attachmentError = nil
    }

    private func setAttachmentError(_ error: AttachmentStagingError) {
        attachmentError = Redaction.safeText(error.description)
    }

    /// Interrupt a running turn (session.interrupt).
    public func interrupt() async {
        guard let sid = openedSessionID, isStreaming else { return }
        do {
            let result = try await session.conversation.interrupt(sessionID: sid)
            if result.isInterrupted {
                finalizeStreamingRow()
                isStreaming = false
                phase = .ready
                await persistTranscript()
            }
        } catch {
            classifyTurnFailure(error)
        }
    }

    // MARK: R10-T4 — voice (client-side STT/TTS; see the seam's deviation note)

    /// Toggle mic capture. First tap authorizes (system sheets); a DENIED
    /// state surfaces honestly (`isVoiceDenied`) and never captures. While
    /// listening, a second tap stops and takes the best PARTIAL (never
    /// auto-submitted). A settled FINAL transcript lands in
    /// `latestVoiceTranscript` for composer review — and auto-submits ONLY
    /// when the user opted into submit-on-silence.
    public func toggleMic() async {
        guard isVoiceAvailable else {
            voiceError = VoiceError.unsupported.description
            return
        }
        guard !isListening else {
            // Manual stop: the in-flight transcribe() returns the best
            // partial (isFinal == false ⇒ review-only, never auto-submit).
            await voice.stopTranscribing()
            return
        }
        let status = await voice.requestAuthorization()
        isVoiceDenied = (status == .denied)
        guard status == .authorized else { return }
        voiceError = nil
        isListening = true
        micTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.voice.transcribe()
                await MainActor.run {
                    self.isListening = false
                    guard let transcript, !transcript.text.isEmpty else { return }
                    self.latestVoiceTranscript = transcript
                    if transcript.isFinal && self.isSubmitOnSilenceEnabled {
                        Task { await self.send(transcript.text) }
                    }
                }
            } catch is CancellationError {
                await MainActor.run { self.isListening = false }
            } catch let error as VoiceError {
                await MainActor.run {
                    self.isListening = false
                    self.voiceError = Redaction.safeText(error.description)
                }
            } catch {
                await MainActor.run {
                    self.isListening = false
                    self.voiceError = VoiceError.captureFailed(Self.nonSecret(error)).description
                }
            }
        }
    }

    /// Voice mode toggle: turning OFF cuts any in-flight speech immediately
    /// (never talks over the user reading).
    public func setVoiceMode(_ enabled: Bool) async {
        isVoiceModeEnabled = enabled
        if !enabled {
            await voice.stopSpeaking()
            await speechQueue.drain()
        }
    }

    /// Dismiss the never-silent voice error banner.
    public func clearVoiceError() {
        voiceError = nil
    }

    /// Clear the pending transcript review chip (used/discard/edit paths).
    public func discardTranscript() {
        latestVoiceTranscript = nil
    }

    /// R10-T4 TTS: speak one assistant text chunk (a streaming delta or a
    /// complete text — see `render` for the exactly-once discipline).
    /// Chunks are NOT trimmed (trimming would concatenate "Hello "+"fleet"
    /// into "Hellofleet"); whitespace-only chunks are skipped.
    private func speakAssistant(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let voice = self.voice
        Task {
            await speechQueue.enqueue {
                try? await voice.speak(text: text)
            }
        }
    }

    // MARK: R9-T2/T3/T4 — tooling actions (steer/rename/fork/usage)

    /// Steer the running turn via the tooling seam (see-through to the
    /// tooling VM; kept here so the view has ONE entry point).
    public func steer(_ text: String) async {
        await toolingViewModel?.steer(text: text)
    }

    /// Rename the open session; adopts the server-resolved title into the
    /// header state on success.
    public func renameSession(title: String) async {
        if let resolved = await toolingViewModel?.rename(title: title) {
            sessionTitle = resolved
        }
    }

    /// Fork the open session (`session.branch`). On success the new session
    /// lands in `forkedSession` for the view to navigate to (the view calls
    /// `consumeForkedSession()` after routing).
    public func forkSession() async {
        guard let branch = await toolingViewModel?.fork(name: nil) else { return }
        forkedSession = branch
    }

    /// Clear the pending fork navigation target (view consumed it).
    public func consumeForkedSession() {
        forkedSession = nil
    }

    /// Refresh the context meter after a completed turn (the streamed ticks
    /// stop at message.complete; the RPC read is the settling figure).
    public func refreshUsageSnapshot() async {
        await toolingViewModel?.refreshUsage()
    }

    /// Cancel background tasks (view disappear). Idempotent.
    ///
    /// P2-3: cancels ONLY the RESTARTABLE status watcher. The event
    /// subscription is one-time (single-subscriber `AsyncStream` — cannot be
    /// re-created after cancellation), so it is left running and dies with the
    /// VM; a re-appear restarts the status watcher via `start()`.
    public func teardown() {
        statusWatcher?.cancel()
        statusWatcher = nil
    }

    // MARK: Cold-start hydration (M10)

    private func hydrateFromCache(sessionID: String) async {
        guard let cached = try? await cache.loadHistory(sessionID: sessionID, for: route.gatewayID),
              !cached.messages.isEmpty else { return }
        allRows = cached.messages.map { Self.row(from: $0, id: nextRowID()) }
        adoptHistoryReactions(into: allRows, from: cached.messages)
        hydratedFromCache = true
        // H1: cached rows landed — the placeholder is no longer needed (rows
        // render immediately). The authoritative fetch still runs to settle
        // the transcript, but the screen already shows real content.
        isHistoryHydrationInProgress = false
        phase = .ready
    }

    /// Replace the cache-hydrated transcript with the authoritative session
    /// projection returned by create/resume (when non-empty).
    private func applyOpenedSession(_ opened: ConversationSession) {
        if !opened.messages.isEmpty {
            // H1 flash-free swap: when the cache already rendered the same
            // history, merge by PRESERVING row ids (the durable gateway
            // row_id, else the existing id) so SwiftUI's ForEach sees the
            // same identities and does not tear down/recreate every bubble
            // — the cache→authoritative handoff must not visibly jump.
            let authoritative = opened.messages
            if hydratedFromCache {
                allRows = Self.mergePreservingIDs(
                    existing: allRows, authoritative: authoritative,
                    nextRowID: { nextRowID() }
                )
            } else {
                allRows = authoritative.map { Self.row(from: $0, id: nextRowID()) }
            }
            adoptHistoryReactions(into: allRows, from: opened.messages)
            hydratedFromCache = false
            isHistoryHydrationInProgress = false
            historyLoadError = nil
        } else if sessionID != nil {
            // H1: the resume projection carried NO messages (the gateway
            // suppresses seeds on resume — verified wire shape), so it is
            // NOT an authoritative "session is empty" — the history state is
            // simply UNKNOWN. Fetch it NOW via the read-only seam, racing
            // the full subscribe pipeline, so populated history renders as
            // soon as the socket is up instead of after the whole stack
            // settles. Whether the cache already rendered rows or not, this
            // is what settles the transcript authoritatively (and swaps
            // ids-preserving when the cache is showing).
            Task { await refetchAuthoritativeHistory(sessionID: opened.sessionID) }
        }
        sessionTitle = opened.profileName
        if let model = opened.model, let provider = opened.provider {
            sessionModel = "\(model) · \(provider)"
        } else if let model = opened.model {
            sessionModel = model
        }
        // R9-T1: the session is open — build the approval banner VM bound to
        // this runtime session id, over the session's approvals seam (nil on
        // sessions without one → the banner surface simply never appears).
        // One cast at build time (see ApprovalsCapable: a same-named
        // extension property recurses through swift_dynamicCast).
        if approvalViewModel == nil {
            if let capable = session as? ApprovalsCapable {
                let vm = ApprovalViewModel(
                    approvals: capable.approvals,
                    biometrics: biometrics,
                    initialYolo: nil
                )
                vm.bind(sessionID: opened.sessionID)
                approvalViewModel = vm
            }
        } else {
            approvalViewModel?.bind(sessionID: opened.sessionID)
        }
        // R9-T2/T3/T4: same one-cast build for the tooling seam (sticky
        // model pick, context meter, steer/rename/fork).
        if toolingViewModel == nil {
            if let capable = session as? ConversationToolingCapable {
                let vm = ConversationToolingViewModel(tooling: capable.tooling, gatewayID: route.gatewayID)
                vm.bind(sessionID: opened.sessionID)
                toolingViewModel = vm
            }
        } else {
            toolingViewModel?.bind(sessionID: opened.sessionID)
        }
        Task { await persistTranscript() }
    }

    // MARK: Event subscription (M5 streaming render)

    private func startEventSubscription() {
        eventTask?.cancel()
        // P2-3: the conversation client's `events` is a SINGLE-SUBSCRIBER
        // AsyncStream — once this task is cancelled, the stream cannot be
        // re-iterated to receive new events (verified empirically). So the
        // event subscription is created ONCE and kept alive for the VM's
        // lifetime; `teardown()` never cancels it. The task holds the VM
        // WEAKLY (per-iteration check, not a strong `guard let self` spanning
        // the whole loop), so it dies naturally with the VM — no leak — and
        // the stream continues to be consumed while the view is temporarily
        // off-screen (no missed events, no dropped reconnect/auth monitoring).
        eventTask = Task { [weak self] in
            guard let session = self?.session else { return }
            let events = session.conversation.events
            for await event in events {
                guard let self, !Task.isCancelled else { break }
                await self.apply(event)
            }
        }
    }

    @MainActor
    private func apply(_ event: ConversationEvent) {
        // Only render events for THIS session (the transport may carry other
        // sessions' events on the same gateway).
        if let sid = event.sessionID, sid != openedSessionID { return }

        // t_8401d3c3 — Last-Event-ID continuity gate: classify the inbound
        // event against the client's own last APPLIED event id before
        // rendering anything. This is the client-side no-gap validation that
        // composes with (not replaces) the transport watermark / RT1
        // replay-hold: it sees exactly what reaches the transcript.
        switch classifyContinuity(event) {
        case .duplicate:
            // Already applied (replayed overlap / duplicate frame) — drop.
            // This is what makes RT1's injected replay batches and the live
            // tail compose without double renders.
            return
        case .gap(let after, let before):
            // Events after `after` and before `before` were never applied.
            // Recover them via targeted last-event-id replay; if the ring no
            // longer holds them, surface the loss explicitly (never silent).
            Task { await recoverGap(after: after, before: before, triggering: event) }
            // Do NOT apply the triggering event yet — recovery re-applies it
            // in order (it will be contiguous then). If recovery fails, the
            // unrecoverable path refetches authoritative history instead.
            return
        case .contiguous, .unknown:
            break
        }

        applyRendered(event)
    }

    /// Continuity classification for one inbound event (t_8401d3c3).
    /// Unstamped events (no seq) and pre-cursor events are `.unknown` — they
    /// apply unconditionally, matching the pre-gate behavior for fixtures
    /// and session-less events; a stamped event after the first establishes
    /// the cursor.
    @MainActor
    private func classifyContinuity(_ event: ConversationEvent) -> EventContinuity {
        guard let sid = event.sessionID, sid == openedSessionID,
              let eventSeq = event.seq else { return .unknown }
        guard let cursor = lastAppliedEventID else {
            return .unknown // first stamped event — establishes the cursor
        }
        if eventSeq <= cursor { return .duplicate }
        if eventSeq == cursor + 1 { return .contiguous }
        return .gap(after: cursor, before: eventSeq)
    }

    /// Apply one event to the transcript and advance the last-applied cursor.
    @MainActor
    private func applyRendered(_ event: ConversationEvent) {
        if let seq = event.seq, event.sessionID == openedSessionID {
            lastAppliedEventID = max(lastAppliedEventID ?? 0, seq)
        }
        render(event)
    }

    /// t_8401d3c3 — gap recovery: fetch the missed tail from the gateway's
    /// replay ring starting at the client's cursor (`session.events.since`),
    /// re-apply it in order, then let the live tail resume contiguously.
    /// Unrecoverable gaps (ring evicted / replay failed) surface an explicit
    /// integrity notice and refetch authoritative history — never silent loss.
    ///
    /// t_e77c614c: generation-fenced — the recovery captures the CURRENT
    /// generation at start (without bumping), so a reconnect / re-auth that
    /// starts while the replay fetch is in flight supersedes it; the stale
    /// recovery never re-applies events, surfaces a notice, or overwrites the
    /// transcript. It deliberately does NOT bump the counter: a background
    /// recovery must never supersede a user recovery (that would drop the
    /// reconnect's `phase = .ready` settlement and strand the screen in
    /// `.reconnecting`).
    private func recoverGap(after: Int, before: Int, triggering: ConversationEvent) async {
        let token = operationGeneration
        guard let sid = openedSessionID else { return }
        do {
            let missed = try await session.conversation.resumeEvents(since: after, sessionID: sid)
            guard isCurrent(token) else { return }
            // Re-apply in seq order, cursor-gated: replayed overlap drops,
            // the missed events + triggering event apply contiguously.
            for event in missed {
                await apply(event)
            }
            // The triggering event was fetched too (seq < before ⇒ replayed);
            // if the ring somehow omitted it, apply it now so the live tail
            // stays contiguous.
            if let tseq = triggering.seq, (lastAppliedEventID ?? 0) < tseq {
                applyRendered(triggering)
            }
            integrityNotice = "Stream gap recovered — \(before - after - 1) missed event\(before - after - 1 == 1 ? "" : "s") replayed."
        } catch ConversationError.gapUnrecoverable(let gsid, let gAfter) {
            guard isCurrent(token) else { return }
            integrityNotice = "Some events after #\(gAfter) are no longer retained — reloading full history."
            await refetchAuthoritativeHistory(sessionID: gsid, fencedBy: token)
        } catch {
            guard isCurrent(token) else { return }
            // Replay attempt failed (transport-level): surface it explicitly
            // and rehydrate from history rather than rendering a hole.
            integrityNotice = "Stream gap could not be recovered — reloading full history."
            await refetchAuthoritativeHistory(sessionID: sid, fencedBy: token)
        }
    }

    /// Authoritative transcript refetch (already the M6 truncation path).
    ///
    /// t_e77c614c: when fenced, a superseded refetch (a newer reconnect /
    /// re-auth / gap recovery already refetched or owns the screen) never
    /// replaces the transcript. `nil` keeps the pre-existing unconditional
    /// behavior for unfenced callers.
    private func refetchAuthoritativeHistory(sessionID: String, fencedBy token: Int? = nil) async {
        // H1: a failed fetch must NEVER wipe the transcript. Cached/projection
        // rows stay rendered, an honest non-secret error surfaces, and the
        // placeholder stays armed only if nothing ever landed (still loading,
        // not failed-slate) — retry rides the next reconnect/replay hydration.
        do {
            let history = try await session.history.fetchSessionHistory(sessionID: sessionID)
            guard isCurrent(token) else { return }
            if history.messages.isEmpty {
                // Authoritative empty (session.history always carries the
                // persisted rows) — the session genuinely has no messages.
                allRows = []
                hydratedFromCache = false
                isHistoryHydrationInProgress = false
                historyLoadError = nil
                return
            }
            if hydratedFromCache {
                // H1 flash-free swap (see applyOpenedSession): preserve row
                // identities across the cache→authoritative handoff.
                allRows = Self.mergePreservingIDs(
                    existing: allRows, authoritative: history.messages,
                    nextRowID: { nextRowID() }
                )
            } else {
                allRows = history.messages.map { Self.row(from: $0, id: nextRowID()) }
            }
            adoptHistoryReactions(into: allRows, from: history.messages)
            hydratedFromCache = false
            isHistoryHydrationInProgress = false
            historyLoadError = nil
            // History is snapshot-authoritative, not event-id tagged: drop the
            // cursor so the next stamped live event re-establishes continuity
            // from the freshest server state instead of false-gap-firing against
            // a stale cursor.
            lastAppliedEventID = nil
            Task { await persistTranscript() }
        } catch {
            guard isCurrent(token) else { return }
            historyLoadError = "History unavailable — \(Self.nonSecret(error))"
        }
    }

    /// The transcript-mutating rendering switch (the former `apply` body).
    private func render(_ event: ConversationEvent) {
        switch event {
        case .messageStart:
            appendRow(.init(id: nextRowID(), kind: .assistant, text: "", isStreaming: true))
            flushPendingReasoning()
            isStreaming = true
            phase = .streaming
            spokenThisTurn = false

        case .messageDelta(_, let text, _, _):
            appendToAssistant(text)
            if isVoiceModeEnabled {
                // R10-T4: chunked TTS — speak each streaming delta as it
                // lands (the desktop speaks streamed chunks; here chunks are
                // local utterances).
                speakAssistant(text)
                spokenThisTurn = true
            }
            if !isStreaming {
                isStreaming = true
                phase = .streaming
            }

        case .messageInterim(_, let text, let alreadyStreamed, _):
            if !alreadyStreamed {
                appendToAssistant(text)
                if isVoiceModeEnabled {
                    // Not streamed as a delta — speak it as its own chunk.
                    speakAssistant(text)
                    spokenThisTurn = true
                }
            }

        case .messageComplete(_, let text, let status, let error, _):
            let isError = status == "error" || error != nil
            if let idx = lastAssistantIndex {
                allRows[idx].text = text.isEmpty ? allRows[idx].text : text
                allRows[idx].isStreaming = false
                allRows[idx].isFailed = isError
            }
            if isVoiceModeEnabled && !spokenThisTurn && !isError && !text.isEmpty {
                // No deltas were spoken (turn arrived as one complete frame) —
                // speak the full text EXACTLY ONCE (never in addition to the
                // already-spoken chunks, which concatenate to the same text).
                speakAssistant(text)
            }
            spokenThisTurn = false
            isStreaming = false
            phase = .ready
            // P0-8: a completed turn must not carry buffered reasoning into
            // the next one (e.g. an errored turn that never minted a row).
            pendingReasoning = nil
            // R9-T3: settle the context meter with the authoritative RPC
            // figure (the streamed ticks stop at this frame).
            Task { await refreshUsageSnapshot() }
            if isError, let error {
                errorMessage = error
            }
            Task { await persistTranscript() }

        case .thinkingDelta(_, let text, _),
             .reasoningDelta(_, let text, _),
             .reasoningAvailable(_, let text, _):
            appendThinking(text)

        case .statusUpdate(_, let kind, let text, _):
            appendRow(.init(id: nextRowID(), kind: .status, text: text, detail: kind))

        case .toolStart(_, _, let name, let context, _, _):
            // P0-8: on the live wire `tool.generating` can arrive BEFORE
            // `tool.start` (probe seq 66 vs 68) and mints a placeholder tool
            // row via updateLastTool. Adopt that row instead of appending a
            // second one — tool names must render as a single chip, never
            // duplicated inline. (Search scoped to the current turn, matching
            // updateLastTool's geometry.)
            let lowerBound = (lastAssistantIndex ?? -1) + 1
            if let idx = allRows[lowerBound...].lastIndex(where: { $0.kind == .tool && $0.text == name }) {
                if let context, !context.isEmpty {
                    allRows[idx].detail = context
                }
            } else {
                appendRow(.init(id: nextRowID(), kind: .tool, text: name, detail: context))
            }

        case .toolGenerating(_, let name, _):
            updateLastTool(name, generating: true)

        case .toolProgress(_, _, let name, let text, _):
            if let name {
                updateLastTool(name, generating: true, progress: text)
            }

        case .toolComplete(_, _, let name, let summary, _):
            updateLastTool(name, generating: false, progress: summary)

        case .backgroundComplete(_, _, let text, _):
            appendRow(.init(id: nextRowID(), kind: .system, text: text ?? "Background task complete"))

        case .sessionInfo(_, let model, let provider, let title, _, _, let yolo, let approvalMode, _):
            if let model, let provider {
                sessionModel = "\(model) · \(provider)"
            } else if let model {
                sessionModel = model
            }
            sessionTitle = title ?? sessionTitle
            // R9-T3: adopt the approval-bypass readback (effective OR of
            // config mode / env / session flag — server.py:7758).
            approvalViewModel?.applySessionInfo(yolo: yolo, approvalMode: approvalMode)

        case .usageUpdate(_, let snapshot, _):
            // R9-T3: live context meter tick (server.py:13133) — applies to
            // the tooling VM only; the transcript is untouched.
            toolingViewModel?.applyUsage(snapshot)

        case .approvalRequested(let sid, let requestID, let command, let detail, let choices, _):
            // R9-T1: surface the blocked dangerous command in the banner.
            // The session filter above already dropped other sessions'
            // approvals; the redaction pass lives in the approval VM.
            approvalViewModel?.handleApprovalRequest(
                ApprovalRequest(
                    requestID: requestID,
                    sessionID: sid,
                    command: command,
                    detail: detail,
                    choices: choices
                )
            )

        case .error(_, let message, _):
            appendRow(.init(id: nextRowID(), kind: .error, text: message, isFailed: true))
            isStreaming = false
            phase = .ready
            errorMessage = message

        case .unknown(_, let rawType, _):
            appendRow(.init(id: nextRowID(), kind: .system, text: "Unknown event: \(rawType)"))
        }
    }

    // MARK: Status watcher — detect mid-stream drop / 4401

    private func startStatusWatcher() {
        statusWatcher?.cancel()
        statusWatcher = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.statusInterval)
                guard !Task.isCancelled else { break }
                // t_a07ca37e: heartbeat-freshness gate — a transport whose
                // last valid frame arrived <12s ago is PROVABLY alive, so the
                // status poll is skipped entirely (Hermex #227: skip status
                // polls while transport-fresh). Nil liveness (test doubles /
                // preview connections) keeps the previous behavior.
                if let snapshot = self.session.liveness,
                   snapshot.tier(toolInFlight: self.isStreaming) == .fresh {
                    continue
                }
                let status = self.session.status
                await self.handleStatusChange(status)
            }
        }
    }

    @MainActor
    private func handleStatusChange(_ status: GatewayStatus) {
        switch status {
        case .offline, .unsupported:
            if phase == .streaming || phase == .ready {
                finalizeStreamingRow()
                isStreaming = false
                phase = .disconnected
                errorMessage = nil
            }
        case .authenticationRequired:
            // M11: 4401 → surface re-auth UX, NEVER a silent retry.
            if phase == .streaming || phase == .ready {
                finalizeStreamingRow()
                isStreaming = false
            }
            phase = .authRequired
            errorMessage = "Authentication required — re-authenticate to continue."
        case .online, .degraded, .connecting:
            break
        }
    }

    // MARK: Replay hydration (M6)

    /// t_e77c614c: when fenced by a recovery token, a superseded hydration
    /// (a newer reconnect / re-auth owns the screen) never surfaces its
    /// notice, refetches history, or settles state.
    private func runReplayHydration(fencedBy token: Int) async {
        do {
            let outcomes = try await session.replay.replayAfterReconnect()
            guard isCurrent(token) else { return }
            replayNotice = Self.replayNotice(outcomes)
            // If the epoch changed or replay was truncated, the authoritative
            // transcript must be refetched (spec §9.5/§9.6). All three paths
            // route through refetchAuthoritativeHistory so the conversation
            // cursor is DROPPED with the snapshot (t_8401d3c3 round 1): the
            // gateway's per-session seq is in-memory, so after a process
            // restart (epoch change) live events restart at seq 1 while the
            // client may hold a high-watermark cursor — a kept cursor would
            // classify the entire next turn as duplicates and drop it
            // silently (the exact loss this card forbids).
            for outcome in outcomes {
                switch outcome {
                case .truncated(let sid), .failed(let sid, _):
                    await refetchAuthoritativeHistory(sessionID: sid, fencedBy: token)
                case .epochChanged:
                    if let sid = openedSessionID {
                        await refetchAuthoritativeHistory(sessionID: sid, fencedBy: token)
                    }
                default:
                    break
                }
            }
        } catch {
            guard isCurrent(token) else { return }
            replayNotice = "Replay unavailable after reconnect."
        }
    }

    // MARK: Transcript mutation helpers

    private var lastAssistantIndex: Int? {
        allRows.lastIndex { $0.kind == .assistant }
    }

    private func appendToAssistant(_ text: String) {
        if let idx = lastAssistantIndex {
            allRows[idx].text += text
            allRows[idx].isStreaming = true
        } else {
            appendRow(.init(id: nextRowID(), kind: .assistant, text: text, isStreaming: true))
            flushPendingReasoning()
        }
    }

    /// P0-8: reasoning/thinking text accumulates in `pendingReasoning` until
    /// THIS turn's assistant row exists. It is never appended to a previous,
    /// completed assistant row — that leaked the previous turn's reasoning
    /// into the new turn's bubble (and, across a resume, foreign session
    /// content into the transcript).
    private func appendThinking(_ text: String) {
        if lastAssistantIndex != nil, isStreaming {
            allRows[lastAssistantIndex!].detail = (allRows[lastAssistantIndex!].detail ?? "") + text
        } else {
            pendingReasoning = (pendingReasoning ?? "") + text
        }
    }

    /// Attach any buffered pre-start reasoning to the freshly created
    /// assistant row and clear the buffer.
    private func flushPendingReasoning() {
        guard let buffered = pendingReasoning, !buffered.isEmpty else { return }
        pendingReasoning = nil
        if let idx = lastAssistantIndex {
            allRows[idx].detail = (allRows[idx].detail ?? "") + buffered
        }
    }

    private func finalizeStreamingRow() {
        guard let idx = lastAssistantIndex else { return }
        allRows[idx].isStreaming = false
    }

    private func updateLastTool(_ name: String, generating: Bool, progress: String? = nil) {
        // P0-8: match within the CURRENT turn only. A turn's tool rows arrive
        // AFTER the previous assistant reply (user → reasoning → tools →
        // message.start), so the search range starts past the last assistant
        // row; before any assistant row exists, the whole transcript is the
        // current turn. Without this, a repeated tool name in a later turn
        // resurrected a finished chip in an earlier one.
        let lowerBound = (lastAssistantIndex ?? -1) + 1
        if let idx = allRows[lowerBound...].lastIndex(where: { $0.kind == .tool && $0.text == name }) {
            if let progress, !progress.isEmpty {
                allRows[idx].detail = progress
            } else {
                allRows[idx].detail = generating ? "Generating…" : allRows[idx].detail
            }
        } else {
            appendRow(.init(id: nextRowID(), kind: .tool, text: name, detail: generating ? "Generating…" : nil))
        }
    }

    private func appendRow(_ row: ConversationRow) {
        allRows.append(row)
    }

    private func nextRowID() -> String {
        rowCounter += 1
        return "row-\(rowCounter)"
    }

    // MARK: Persistence (M10 — cold-start history)

    private func persistTranscript() async {
        guard let sid = openedSessionID else { return }
        // P2-8: persist the AUTHORITATIVE history (`allRows`), never the capped
        // display window — so retention never loses history from the cache.
        let messages = allRows.compactMap { Self.sessionMessage(from: $0) }
        try? await cache.saveHistory(
            SessionHistory(sessionID: sid, count: messages.count, messages: messages),
            for: route.gatewayID
        )
    }

    // MARK: R10-T2 — message reactions (Tapback)

    /// React to (or toggle) one transcript row's message via `message.react`.
    ///
    /// Target resolution: the row's durable `row_id` when it has one; a live
    /// row (streamed this session, not yet round-tripped through a resume)
    /// addresses `newest_role` — the newest persisted row of that role,
    /// which is the message the user just reacted to
    /// (methods_session.py:1576-1579). Re-sending the same emoji is a
    /// server-side RETRACT (hermes_state.py:13008) — the client toggles by
    /// sending again. Optimistic update with rollback on error; server truth
    /// (the post-write reaction list) settles the row.
    public func react(rowID: String?, kind: ConversationRow.Kind = .user, emoji: String) async {
        reactionError = nil
        guard let sid = openedSessionID else {
            reactionError = "Reactions need an open session"
            return
        }
        // Resolve the wire target.
        let target: MessageReactionTarget
        if let rowID {
            target = .durable(rowID: rowID)
        } else {
            guard let role = Self.wireRole(for: kind),
                  let live = MessageReactionTarget(liveRole: role) else {
                reactionError = "This message can't be reacted to yet"
                return
            }
            target = live
        }
        // Optimistic update keyed on the ROW id the UI addressed (durable id
        // when present, else the transcript row id).
        let displayKey = rowID ?? Self.liveRowKey(kind: kind)
        let prior = reactionsByRowID[displayKey] ?? .empty
        let optimistic = prior.applyingOwnReaction(emoji)
        reactionsByRowID[displayKey] = optimistic
        do {
            let result = try await reactionSeam.react(sessionID: sid, target: target, emoji: emoji)
            // Server truth settles — keyed on the durable id the write
            // landed on. On the live path (newest_role) the addressed row
            // is PROMOTED to that durable id, so it projects through this
            // key and the chip survives the settle (QA round-1 defect: the
            // settle used to drop the live-* key while the row still
            // projected through it — the chip vanished exactly when the
            // server confirmed it).
            let snapshot = MessageReactionsSnapshot(result)
            if snapshot.reactions.isEmpty {
                reactionsByRowID.removeValue(forKey: result.rowID)
            } else {
                reactionsByRowID[result.rowID] = snapshot
            }
            settleReactionKeys(wireTarget: target, displayKey: displayKey, resultRowID: result.rowID)
        } catch {
            // Rollback: restore the pre-optimistic state (absent = none).
            if prior.reactions.isEmpty {
                reactionsByRowID.removeValue(forKey: displayKey)
            } else {
                reactionsByRowID[displayKey] = prior
            }
            reactionError = Self.nonSecret(error)
        }
    }

    /// Clear the local user's reaction on a row (`emoji: null`).
    public func clearReaction(rowID: String?, kind: ConversationRow.Kind = .user) async {
        reactionError = nil
        guard let sid = openedSessionID else {
            reactionError = "Reactions need an open session"
            return
        }
        let target: MessageReactionTarget
        if let rowID {
            target = .durable(rowID: rowID)
        } else {
            guard let role = Self.wireRole(for: kind),
                  let live = MessageReactionTarget(liveRole: role) else {
                reactionError = "This message can't be reacted to yet"
                return
            }
            target = live
        }
        let displayKey = rowID ?? Self.liveRowKey(kind: kind)
        let prior = reactionsByRowID[displayKey] ?? .empty
        let optimistic = prior.clearingOwnReaction()
        if optimistic.reactions.isEmpty {
            reactionsByRowID.removeValue(forKey: displayKey)
        } else {
            reactionsByRowID[displayKey] = optimistic
        }
        do {
            let result = try await reactionSeam.react(sessionID: sid, target: target, emoji: nil)
            if result.reactions.isEmpty {
                reactionsByRowID.removeValue(forKey: result.rowID)
            } else {
                reactionsByRowID[result.rowID] = MessageReactionsSnapshot(result)
            }
            settleReactionKeys(wireTarget: target, displayKey: displayKey, resultRowID: result.rowID)
        } catch {
            if prior.reactions.isEmpty {
                reactionsByRowID.removeValue(forKey: displayKey)
            } else {
                reactionsByRowID[displayKey] = prior
            }
            reactionError = Self.nonSecret(error)
        }
    }

    /// Dismiss the reaction error banner.
    public func clearReactionError() {
        reactionError = nil
    }

    /// The wire role a live row maps to (only user/assistant rows are
    /// reactable via newest_role; tool/status/system rows are not).
    static func wireRole(for kind: ConversationRow.Kind) -> String? {
        switch kind {
        case .user: return "user"
        case .assistant: return "assistant"
        default: return nil
        }
    }

    /// Stable in-flight key for a live (row_id-less) row awaiting its
    /// durable id from the server.
    static func liveRowKey(kind: ConversationRow.Kind) -> String {
        "live-\(kind == .user ? "user" : "assistant")"
    }

    /// Post-settle key reconciliation for a reaction write (QA round-1
    /// defect fix). The optimistic update keyed under `displayKey` (durable
    /// id or live-* key); server truth lands under `resultRowID`.
    /// - Durable path: the keys match, nothing to reconcile.
    /// - Live path (newest_role): the newest LIVE row of that kind is
    ///   PROMOTED to `resultRowID` — it now projects through the durable
    ///   key, so the settled chip stays visible and Clear Reaction remains
    ///   reachable — and the in-flight live-* entry is dropped.
    private func settleReactionKeys(
        wireTarget: MessageReactionTarget,
        displayKey: String,
        resultRowID: String
    ) {
        if wireTarget.rowID != nil {
            // Durable write: server truth settled under the same key the
            // optimistic update used. Nothing to reconcile.
            return
        }
        guard let role = wireTarget.newestRole else { return }
        let kind: ConversationRow.Kind = role == "user" ? .user : .assistant
        // Promote the newest live row of this kind to the durable id the
        // server assigned. Skip when no live row addresses it (e.g. the row
        // already round-tripped through a resume — then a durable row
        // carries the same id and no live-* key exists to reconcile).
        if let idx = allRows.lastIndex(where: {
            $0.kind == kind && $0.rowID == nil
        }) {
            allRows[idx].rowID = resultRowID
        }
        // Drop the in-flight live-* entry (the promoted row now reads the
        // durable key; a next live write optimistically starts fresh).
        if displayKey != resultRowID {
            reactionsByRowID.removeValue(forKey: displayKey)
        }
    }

    /// Adopt history-carried reactions when rows (re)load (durable rows
    /// only — live rows never carry them on the wire). Rows without a
    /// durable row_id cannot be keyed — their reactions (if any ever appear)
    /// are ignored.
    private func adoptHistoryReactions(into rows: [ConversationRow], from messages: [SessionMessage]) {
        for (row, message) in zip(rows, messages) {
            guard let durableID = row.rowID else { continue }
            if let reactions = message.reactions {
                if reactions.isEmpty {
                    reactionsByRowID.removeValue(forKey: durableID)
                } else {
                    reactionsByRowID[durableID] = MessageReactionsSnapshot(reactions: reactions)
                }
            }
        }
    }

    // MARK: Failure classification

    private func classifyConnectFailure(_ error: any Error) {
        switch error {
        case let connectivity as GatewayConnectivityError:
            switch connectivity {
            case .authenticationRequired:
                phase = .authRequired
                errorMessage = "Authentication required — re-authenticate to continue."
            default:
                phase = .failed(Self.nonSecret(error))
            }
        default:
            phase = .failed(Self.nonSecret(error))
        }
    }

    private func classifyOpenFailure(_ error: any Error) {
        switch error {
        case let conversation as ConversationError:
            switch conversation {
            case .sessionNotFound(let detail):
                phase = .failed("Session not found: \(detail). Start a new conversation.")
            default:
                phase = .failed(Self.nonSecret(error))
            }
        default:
            phase = .failed(Self.nonSecret(error))
        }
    }

    private func classifyTurnFailure(_ error: any Error) {
        switch error {
        case let conversation as ConversationError:
            if case .sessionNotFound(let detail) = conversation {
                phase = .failed("Session not found: \(detail). Start a new conversation.")
            } else {
                errorMessage = Self.nonSecret(error)
                phase = .ready
            }
        default:
            errorMessage = Self.nonSecret(error)
            phase = .ready
        }
    }

    // MARK: Static mapping helpers

    /// H1 (t_01c9d411) — flash-free cache→authoritative swap. Rebuilds rows
    /// from the authoritative messages while PRESERVING identity where the
    /// cache already rendered the same content: a durable gateway `row_id`
    /// match, else an exact content match (kind+text+detail+timestamp) at
    /// the same list position. Unmatched messages get fresh ids. Same
    /// identity ⇒ SwiftUI's ForEach updates bubbles in place instead of
    /// tearing the transcript down and re-popping every row.
    static public func mergePreservingIDs(
        existing: [ConversationRow],
        authoritative: [SessionMessage],
        nextRowID: () -> String
    ) -> [ConversationRow] {
        var byDurableID: [String: String] = [:] // row_id -> rendered row id
        for row in existing {
            if let durable = row.rowID {
                byDurableID[durable] = row.id
            }
        }
        var merged: [ConversationRow] = []
        merged.reserveCapacity(authoritative.count)
        for message in authoritative {
            // Resolve the identity FIRST (id is a let on ConversationRow).
            var id: String
            if let durable = message.rowID, let preserved = byDurableID[durable] {
                id = preserved
            } else if message.rowID == nil,
                      let preserved = contentMatchID(at: merged.count, in: existing, for: message) {
                id = preserved
            } else {
                id = nextRowID()
            }
            merged.append(Self.row(from: message, id: id))
        }
        return merged
    }

    /// Content-match fallback for messages without a durable row_id: the
    /// cached and authoritative lists are both transcript-ordered, so an
    /// exact kind+text+detail+timestamp match at the same position keeps
    /// its rendered id.
    private static func contentMatchID(
        at index: Int, in existing: [ConversationRow], for message: SessionMessage
    ) -> String? {
        guard index < existing.count, existing[index].rowID == nil else { return nil }
        let candidate = Self.row(from: message, id: existing[index].id)
        return existing[index].kind == candidate.kind
            && existing[index].text == candidate.text
            && existing[index].detail == candidate.detail
            && existing[index].timestamp == candidate.timestamp
            ? existing[index].id : nil
    }

    /// Map a persisted `SessionMessage` (history projection) onto a rendered row.
    /// R10-T2: the durable `row_id` rides onto the row (the reaction write
    /// target); history-carried reactions seed `reactionsByRowID` via
    /// `adoptHistoryReactions`.
    static func row(from message: SessionMessage, id: String) -> ConversationRow {
        switch message.role {
        case .user:
            return .init(id: id, kind: .user, text: message.text, timestamp: message.timestamp, rowID: message.rowID)
        case .assistant:
            return .init(id: id, kind: .assistant, text: message.text, detail: message.reasoning, timestamp: message.timestamp, rowID: message.rowID)
        case .tool:
            return .init(id: id, kind: .tool, text: message.toolName ?? message.text, detail: message.toolContext, timestamp: message.timestamp, rowID: message.rowID)
        case .system:
            return .init(id: id, kind: .system, text: message.text, timestamp: message.timestamp, rowID: message.rowID)
        case .unknown:
            return .init(id: id, kind: .system, text: message.text, timestamp: message.timestamp, rowID: message.rowID)
        }
    }

    /// Reverse-map a rendered row onto a persisted `SessionMessage` (M10).
    /// U6: the display-only timestamp round-trips so a cached transcript keeps
    /// its stamped times across re-persists (rows without one stay unstamped).
    static func sessionMessage(from row: ConversationRow) -> SessionMessage? {
        switch row.kind {
        case .user:
            return .init(role: .user, text: row.text, timestamp: row.timestamp)
        case .assistant:
            return .init(role: .assistant, text: row.text, timestamp: row.timestamp, reasoning: row.detail)
        case .tool:
            return .init(role: .tool, text: row.text, timestamp: row.timestamp, toolName: row.text, toolContext: row.detail)
        case .status, .system:
            return .init(role: .system, text: row.text, timestamp: row.timestamp, toolName: row.detail)
        case .error:
            return nil // errors are transient UI state, not persisted history
        }
    }

    static func nonSecret(_ error: any Error) -> String {
        Redaction.safeErrorDescription(error)
    }

    /// Human-readable replay hydration notice (non-secret; spec §30 answers
    /// "what happened" without leaking credentials).
    static func replayNotice(_ outcomes: [ReplayOutcome]) -> String {
        guard !outcomes.isEmpty else { return "Reconnected." }
        let parts = outcomes.map { outcome -> String in
            switch outcome {
            case .replayed(_, let count):
                return "replayed \(count) missed event\(count == 1 ? "" : "s")"
            case .truncated:
                return "history refreshed"
            case .epochChanged:
                return "gateway restarted — history refreshed"
            case .failed(_, let detail):
                return "replay failed: \(detail)"
            case .nothingToReplay:
                return "nothing new"
            }
        }
        return "Reconnected · " + parts.joined(separator: ", ")
    }
}

// MARK: - R9-T1 default biometric seam

/// Default `AppLockBiometricAuth` when the composition root injects none:
/// treats every evaluation as failed — the approval banner's APPROVE path
/// fails CLOSED (the command stays blocked) instead of crashing or silently
/// approving. Production injects the real `LocalAuthenticationBiometricAuth`
/// (or the scripted H1 provider in DEBUG).
public struct NeverLockBiometricAuth: AppLockBiometricAuth {
    public init() {}

    public func canEvaluateBiometrics() -> Bool { false }

    public func evaluateBiometrics(reason: String) async -> AppLockAuthResult {
        .unavailable
    }

    public func evaluateDevicePasscode(reason: String) async -> Bool { false }
}

// MARK: - R10-T5 TTS ordering

/// Serializes TTS chunk speaks: streaming deltas arrive sequentially through
/// the VM's event consumer, but each speak is an async call — without a
/// queue, two chunks could reach the synthesizer out of order (spoken audio
/// garbled). An actor runs the closures strictly in enqueue order.
actor SpeechQueue {
    private var pending: [@Sendable () async -> Void] = []
    private var isDraining = false

    func enqueue(_ work: @escaping @Sendable () async -> Void) async {
        pending.append(work)
        guard !isDraining else { return }
        isDraining = true
        while !pending.isEmpty {
            let next = pending.removeFirst()
            await next()
        }
        isDraining = false
    }

    /// Drop queued (not yet spoken) chunks — called when speech is cut
    /// (new user turn / voice mode off): a stale chunk must never play
    /// after the cut.
    func drain() {
        pending.removeAll()
    }
}
