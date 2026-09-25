import Foundation
import os
import FleetCore

/// t_3b321b7b — the Hermex `KanbanEventStreamClient` pattern, ported to the
/// Hermes dashboard's kanban plugin surface.
///
/// Wire contract (verified against `plugins/kanban/dashboard/plugin_api.py`):
/// - `GET {base}/api/plugins/kanban/board` → the full board grouped by status
///   column, plus `latest_event_id` (the resume cursor) and `now`.
/// - `WS {base}/api/plugins/kanban/events?since=<cursor>` → frames of
///   `{"events":[{id,task_id,run_id,kind,payload,created_at},…],"cursor":N}`
///   — the append-only `task_events` tail (`WHERE id > cursor`), so a client
///   that reconnects with its last cursor loses nothing.
///
/// Auth (one seam per gateway, no second credential path):
/// - WS upgrade goes through the dashboard's canonical `_ws_auth_ok` gate:
///   `?ticket=` (single-use, minted via the same `POST /api/auth/ws-ticket`
///   the conversation transport uses) or `?token=` (loopback). Both are
///   modeled by `ConnectionAuthentication`, produced by the injected
///   `AuthenticationProviding` — the SAME provider the app graph builds for
///   this gateway.
/// - HTTP board fetches go through the dashboard's session middleware:
///   `X-Hermes-Session-Token` header (loopback/session-token strategies —
///   the stored credential) or the login `Cookie` (username/password
///   strategy — a fresh `POST /auth/password-login` per fetch, matching the
///   ticket-mint freshness discipline; snapshot fetches are infrequent).
public actor KanbanEventStreamClient: KanbanBoardWatching, GatewaySessionDisconnecting {
    public let gatewayID: GatewayID

    /// HTTP base of the dashboard server (`http(s)://host:port`).
    private let baseURL: URL
    /// WS auth seam — same provider the conversation transport uses.
    private let authenticator: any AuthenticationProviding
    /// HTTP credential resolution for the board fetch, per auth strategy.
    private let httpCredential: @Sendable () async throws -> HTTPCredential
    private let urlSession: any GatewayHTTPClient
    /// WebSocket session factory — the SAME pinning-aware seam the transport
    /// uses (`URLSessionWebSocketSessionFactory(trustHandler:)` in
    /// production), so kanban sockets enforce the gateway's TOFU pin too.
    private let sessionFactory: any WebSocketSessionFactory
    /// Reconnect backoff: base + cap (seconds). Testable injection.
    private let reconnectDelay: (base: Double, cap: Double)

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "kanban-stream")

    /// The HTTP credential for one board fetch. Never printed (spec §29).
    public enum HTTPCredential: Sendable {
        case none
        case sessionTokenHeader(String)
        case cookie(SessionCookie)
    }

    // MARK: State (actor-isolated)

    private var lastCursor: Int = 0
    private var stopped = false
    /// Pinned board slug (t_624b81cd — client-side selection). nil = the
    /// gateway operator's ACTIVE board (no `?board=` param rides any URL).
    private var pinnedBoard: String?
    /// Active change-event subscribers (fan-out: every subscriber sees every
    /// batch; the socket loop is owned internally, one pump at a time).
    private var subscribers: [UUID: AsyncStream<KanbanEventBatch>.Continuation] = [:]
    /// The active socket-pump task.
    private var pumpTask: Task<Void, Never>?

    public init(
        gatewayID: GatewayID,
        baseURL: URL,
        authenticator: any AuthenticationProviding,
        httpCredential: @escaping @Sendable () async throws -> HTTPCredential = { .none },
        urlSession: any GatewayHTTPClient = URLSession.shared,
        sessionFactory: any WebSocketSessionFactory = URLSessionWebSocketSessionFactory(),
        reconnectDelay: (base: Double, cap: Double) = (base: 1.0, cap: 15.0)
    ) {
        self.gatewayID = gatewayID
        self.baseURL = baseURL
        self.authenticator = authenticator
        self.httpCredential = httpCredential
        self.urlSession = urlSession
        self.sessionFactory = sessionFactory
        self.reconnectDelay = reconnectDelay
    }

    // MARK: - Snapshot (HTTP)

    public struct BoardEnvelope: Decodable, Sendable {
        public let columns: [ColumnEnvelope]
        public let latest_event_id: Int
        public let now: Double?
        public struct ColumnEnvelope: Decodable, Sendable {
            public let name: String
            public let tasks: [TaskEnvelope]
        }
        public struct TaskEnvelope: Decodable, Sendable {
            public let id: String
            public let title: String?
            public let status: String?
            public let assignee: String?
            public let priority: Int?
            public let created_at: Double?
            public let latest_summary: String?
        }
    }

    // MARK: Board selection (t_624b81cd — client-side only, never /switch)

    /// The pinned board slug, or nil when following the gateway's active
    /// board. Test/inspection accessor.
    public var board: String? { pinnedBoard }

    /// The event cursor a fresh stream would resume from. Test accessor.
    public var resumeCursor: Int { lastCursor }

    /// Pin which board snapshot + event URLs target. Callers own stream
    /// lifecycle around a switch: cancel the stream task, pin, then
    /// re-subscribe — the socket loop's next connection re-opens pinned to
    /// the new slug. Resetting the cursor is unconditional: event ids are
    /// per-board sequences, so the old cursor must not vouch for the new
    /// board (same discipline as H2's "no stale liveness across resets").
    ///
    /// This is CLIENT-SIDE only: `POST /boards/{slug}/switch` is never
    /// called — that endpoint repoints the orchestrator Mac's active board
    /// (known fleet failure mode).
    public func pinBoard(_ slug: String?) {
        guard slug != pinnedBoard else { return }
        pinnedBoard = slug
        lastCursor = 0
    }

    /// `GET /boards` — every board with counts + the operator's active slug.
    public func fetchBoards() async throws -> KanbanBoardList {
        var request = URLRequest(
            url: Self.buildBoardsListURL(base: baseURL))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AuthREST.bounded(&request)
        try await applyHTTPCredential(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard data.count <= AuthREST.maxResponseBytes else {
            throw KanbanBoardError.malformedResponse("boards response too large")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.log.error("kanban boards: HTTP \(http.statusCode)")
            throw KanbanBoardError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(KanbanBoardList.self, from: data)
        } catch {
            throw KanbanBoardError.malformedResponse("boards decode failed")
        }
    }

    /// Apply the resolved HTTP credential to a plugin request (shared by the
    /// snapshot + boards fetches). Credential-resolution failures propagate
    /// (a failed password login is an error state, not a silent anonymous
    /// request).
    private func applyHTTPCredential(to request: inout URLRequest) async throws {
        switch try await httpCredential() {
        case .none:
            break
        case .sessionTokenHeader(let token):
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        case .cookie(let cookie):
            request.setValue(cookie.headerValue, forHTTPHeaderField: "Cookie")
        }
    }

    public func snapshot() async throws -> KanbanBoardSnapshot {
        guard let boardURL = Self.buildBoardURL(base: baseURL, board: pinnedBoard) else {
            throw KanbanBoardError.malformedResponse("bad board URL")
        }
        var request = URLRequest(url: boardURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AuthREST.bounded(&request)
        try await applyHTTPCredential(to: &request)

        let (data, response) = try await urlSession.data(for: request)
        guard data.count <= AuthREST.maxResponseBytes else {
            throw KanbanBoardError.malformedResponse("board response too large")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.log.error("kanban board: HTTP \(http.statusCode)")
            throw KanbanBoardError.httpStatus(http.statusCode)
        }
        let envelope: BoardEnvelope
        do {
            envelope = try JSONDecoder().decode(BoardEnvelope.self, from: data)
        } catch {
            throw KanbanBoardError.malformedResponse("board decode failed")
        }
        var cardsByColumn: [String: [KanbanCard]] = [:]
        for column in envelope.columns {
            cardsByColumn[column.name] = column.tasks.map { task in
                KanbanCard(
                    id: task.id,
                    title: task.title ?? task.id,
                    status: task.status ?? column.name,
                    assignee: task.assignee,
                    priority: task.priority,
                    createdAt: task.created_at,
                    latestSummary: task.latest_summary
                )
            }
        }
        let snapshot = KanbanBoardSnapshot(
            columns: envelope.columns.map(\.name),
            cardsByColumn: cardsByColumn,
            latestEventID: Int(envelope.latest_event_id),
            now: envelope.now
        )
        // Adopt the snapshot cursor so a stream opened afterwards resumes
        // from exactly here (the dashboard's own client does the same).
        if snapshot.latestEventID > lastCursor {
            lastCursor = snapshot.latestEventID
        }
        return snapshot
    }

    // MARK: - Event stream (WS tail)

    public func changeEvents() async -> AsyncStream<KanbanEventBatch> {
        // Runs on the actor: subscriber registration + pump start are
        // isolated state mutations.
        // A watcher is retained by AppEnvironment across view lifecycles so
        // the app can stop it at a background/lock boundary. A later board
        // view is a deliberate new owner, so make that watcher restartable.
        stopped = false
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
            ensurePumpRunning()
        }
    }

    private func removeSubscriber(_ id: UUID) async {
        subscribers[id] = nil
        if subscribers.isEmpty {
            stopPump()
        }
    }

    private func ensurePumpRunning() {
        guard !stopped else { return }
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            await self?.runPump()
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// The socket pump: connect → tail frames → fan out → on drop, backoff
    /// and reconnect from `lastCursor`. Runs until stopped or the last
    /// subscriber leaves.
    private func runPump() async {
        var attempt = 0
        while !stopped {
            do {
                try await pumpOneConnection()
                attempt = 0 // clean end (stop()) → reset backoff
            } catch is CancellationError {
                break
            } catch {
                if stopped { break }
                attempt += 1
                let delay = min(
                    reconnectDelay.cap,
                    reconnectDelay.base * pow(2, Double(attempt - 1)))
                Self.log.warning(
                    "kanban stream dropped (attempt \(attempt, privacy: .public), retry in \(delay, privacy: .public)s)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// One WebSocket connection: handshake → loop over inbound frames →
    /// fan each parsed batch out to subscribers and advance the cursor.
    /// Returns when the socket ends; throws on drops the caller should
    /// back off for. `CancellationError` propagates on stop().
    private func pumpOneConnection() async throws {
        let authentication = try await authenticator.authenticate()
        guard let url = Self.buildEventsURL(
            base: baseURL,
            since: lastCursor,
            board: pinnedBoard,
            authentication: authentication
        ) else {
            throw KanbanBoardError.streamDropped("bad events URL")
        }
        let session = sessionFactory.makeSession(url: url)
        try await session.open()
        defer { Task { await session.close(code: 1001, reason: nil) } }
        Self.log.info("kanban stream connected (since=\(self.lastCursor, privacy: .public))")

        while true {
            let message: WebSocketMessage
            do {
                message = try await session.receive()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Receive failure = socket done (server close / network
                // drop) → caller reconnects from the cursor.
                throw KanbanBoardError.streamDropped("socket receive failed")
            }
            guard case .text(let text) = message else { continue } // binary: ignore
            guard let batch = Self.parseEventFrame(text) else {
                Self.log.warning("kanban stream: unparsable frame dropped")
                continue
            }
            if batch.cursor > lastCursor {
                lastCursor = batch.cursor
            }
            for continuation in subscribers.values {
                continuation.yield(batch)
            }
        }
    }

    public func stop() async {
        stopped = true
        stopPump()
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    public func disconnect() async {
        await stop()
    }

    // MARK: Wire helpers (pure, testable)

    /// Build the snapshot URL: `…/api/plugins/kanban/board` plus
    /// `?board=<slug>` when pinned (nil = the server's active board; the
    /// param is simply omitted). Query-safe for any legal slug.
    public static func buildBoardURL(base: URL, board: String?) -> URL? {
        var components = URLComponents(
            url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/plugins/kanban/board"
        if let board, !board.isEmpty {
            components?.queryItems = [
                URLQueryItem(name: "board", value: board)
            ]
        }
        return components?.url
    }

    /// Build the boards-list URL: `…/api/plugins/kanban/boards`.
    public static func buildBoardsListURL(base: URL) -> URL {
        var components = URLComponents(
            url: base, resolvingAgainstBaseURL: false)!
        components.path = "/api/plugins/kanban/boards"
        components.query = nil
        return components.url!
    }

    /// Build `ws(s)://host:port/api/plugins/kanban/events?since=N` with the
    /// connection's auth query (`?ticket=` / `?token=`) and, when pinned,
    /// `&board=<slug>` (board is pinned at handshake — a switch means a NEW
    /// socket) — mirrors `GatewayWebSocketTransport.buildWebSocketURL` (the
    /// secret rides in the returned URL; never log it directly, spec §29).
    public static func buildEventsURL(
        base: URL,
        since: Int,
        board: String? = nil,
        authentication: ConnectionAuthentication
    ) -> URL? {
        guard var components = URLComponents(
            url: base, resolvingAgainstBaseURL: false
        ) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        components.path = "/api/plugins/kanban/events"
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "since", value: String(since)))
        if let board, !board.isEmpty {
            query.append(URLQueryItem(name: "board", value: board))
        }
        switch authentication {
        case .none:
            break
        case .ticket(let token):
            query.append(URLQueryItem(name: "ticket", value: token.rawValue))
        case .loopbackToken(let token):
            query.append(URLQueryItem(name: "token", value: token.rawValue))
        }
        components.queryItems = query
        return components.url
    }

    /// One inbound tail event (`task_events` row shape).
    public struct EventEnvelope: Decodable, Sendable {
        public let id: Int
        public let task_id: String
        public let kind: String
        public let created_at: Double?
    }

    /// One stream frame: `{"events":[…],"cursor":N}`.
    public struct FrameEnvelope: Decodable, Sendable {
        public let events: [EventEnvelope]
        public let cursor: Int
    }

    /// Parse one text frame into a domain batch. nil when the frame is not
    /// the expected shape (logged + dropped by the caller).
    public static func parseEventFrame(_ text: String) -> KanbanEventBatch? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let frame = try? JSONDecoder().decode(FrameEnvelope.self, from: data) else {
            return nil
        }
        return KanbanEventBatch(
            events: frame.events.map {
                KanbanChangeEvent(
                    id: $0.id, taskID: $0.task_id, kind: $0.kind,
                    createdAt: $0.created_at)
            },
            cursor: frame.cursor
        )
    }
}
