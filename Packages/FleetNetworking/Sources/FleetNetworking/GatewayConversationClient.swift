import Foundation
import FleetCore

/// Concrete `ConversationProviding` for the Hermes gateway conversation path:
/// `session.create` / `session.resume` / `prompt.submit` / `session.interrupt`
/// over the WebSocket JSON-RPC transport, plus streamed turn-event rendering
/// (`message.*`, `tool.*`, `status.*`, `thinking/reasoning.*`,
/// `message.complete`).
///
/// M5 scope (spec §31 Conversation). Every RPC corresponds to an explicit user
/// action — this is the MUTATING seam and is deliberately separate from the M4
/// read-only `SessionHistoryProviding`: a read-only screen structurally cannot
/// reach this type (the composition root decides which seam to hand a screen).
public struct GatewayConversationClient: ConversationProviding, ReasoningEffortCreating {
    /// The gateway this client is bound to.
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    /// Stream of conversation events for this gateway's sessions. P0-7: a
    /// FRESH stream per access — the view model captures it once when it
    /// starts its event subscription, and that subscription dies with the view
    /// model when the conversation screen is popped. The transport fans every
    /// decoded event out to all live subscribers, so a re-entered conversation
    /// (new view model, same cached per-gateway session) receives a live pipe
    /// instead of iterating the previous consumer's dead one. Iterate it
    /// BEFORE submitting a prompt so no streamed event is missed.
    public var events: AsyncStream<ConversationEvent> {
        Self.eventStream(transport: transport)
    }

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: ConversationProviding

    public func createSession(
        title: String?,
        profile: String?,
        model: String?,
        provider: String?,
        cols: Int?
    ) async throws -> ConversationSession {
        try await createSessionWithEffort(
            title: title, profile: profile, model: model, provider: provider,
            reasoningEffort: nil, cols: cols)
    }

    /// `session.create` with an optional per-session `reasoning_effort`
    /// (tui_gateway/contracts/sessions.py; a level STRING such as
    /// "medium" or "none", never a token budget). Omitted when nil so the
    /// session inherits the profile effort.
    public func createSessionWithEffort(
        title: String?,
        profile: String?,
        model: String?,
        provider: String?,
        reasoningEffort: ReasoningEffort?,
        cols: Int?
    ) async throws -> ConversationSession {
        // M9 fail-closed guard: an unsafe profile slug never reaches the
        // transport (path traversal into the gateway's profile namespace).
        if let profile, !RoutingGuard.isValidRouteComponent(profile) {
            throw ConversationError.invalidSessionKey("profile is not a safe routing key: \(profile)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        var params: [String: JSONValue] = [:]
        if let title { params["title"] = .string(title) }
        if let profile { params["profile"] = .string(profile) }
        if let model { params["model"] = .string(model) }
        if let provider { params["provider"] = .string(provider) }
        if let reasoningEffort { params["reasoning_effort"] = .string(reasoningEffort.rawValue) }
        if let cols { params["cols"] = .number(Double(cols)) }
        do {
            let result = try await transport.request(method: "session.create", params: .object(params))
            return try Self.decodeSession(result)
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    public func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        // t_8401d3c3 (Last-Event-ID subscribe): declare the resume point on
        // every subscribe/reconnect. The gateway reads only known keys on
        // `session.resume` and ignores extras (verified methods_session.py),
        // so this is wire-safe today; when the server adopts `last_seen` on
        // resume it becomes the server-side resume filter.
        if let lastEventID {
            params["last_seen"] = .number(Double(lastEventID))
        }
        let paramsValue = JSONValue.object(params)
        do {
            let result = try await transport.request(method: "session.resume", params: paramsValue)
            return try Self.decodeSession(result)
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    public func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "text": .string(text),
        ])
        do {
            let result = try await transport.request(method: "prompt.submit", params: params)
            guard let status = result["status"]?.stringValue else {
                throw ConversationError.malformedPayload("prompt.submit result missing 'status'")
            }
            return PromptSubmission(status: status)
        } catch let error as ConversationError {
            throw error
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    public func interrupt(sessionID: String) async throws -> InterruptResult {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object(["session_id": .string(sessionID)])
        do {
            let result = try await transport.request(method: "session.interrupt", params: params)
            guard let status = result["status"]?.stringValue else {
                throw ConversationError.malformedPayload("session.interrupt result missing 'status'")
            }
            return InterruptResult(status: status, turnIsolation: result["turn_isolation"]?.boolValue)
        } catch let error as ConversationError {
            throw error
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    /// t_8401d3c3 (Last-Event-ID resume): recover the missed tail of one
    /// session's stream from the gateway's replay ring. Issues the existing
    /// read-only `session.events.since(session_id, last_seen)` RPC with the
    /// CLIENT's last applied event id, decodes the bare replay events, and
    /// maps them onto the conversation domain.
    ///
    /// Fail-closed on unrecoverable gaps: `truncated == true` means the ring
    /// no longer retains everything after `lastEventID` — throwing
    /// `.gapUnrecoverable` (instead of returning a partial batch) guarantees
    /// the caller refetches authoritative history rather than silently
    /// losing the evicted events.
    public func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "last_seen": .number(Double(lastEventID)),
        ])
        do {
            let result = try await transport.request(method: "session.events.since", params: params)
            let batch = try GatewayReplayClient.decode(sessionID: sessionID, result)
            if batch.truncated {
                throw ConversationError.gapUnrecoverable(sessionID: sessionID, afterEventID: lastEventID)
            }
            return batch.events.compactMap(Self.decodeEvent)
        } catch let error as ConversationError {
            throw error
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    // MARK: decoding (wire → domain)

    /// `session.create` / `session.resume` →
    /// `{session_id, stored_session_id?, message_count, messages: [...],
    /// info?: {model?, provider?, profile_name?}}`.
    static func decodeSession(_ result: JSONValue) throws -> ConversationSession {
        guard let sessionID = result["session_id"]?.stringValue, !sessionID.isEmpty else {
            throw ConversationError.malformedPayload("conversation result missing 'session_id'")
        }
        let messages = result["messages"]?.arrayValue?
            .compactMap(GatewaySessionHistoryClient.decodeMessage) ?? []
        let count = result["message_count"]?.numberValue.map(Int.init) ?? messages.count
        let info = result["info"]?.objectValue ?? [:]
        return ConversationSession(
            sessionID: sessionID,
            storedSessionID: result["stored_session_id"]?.stringValue,
            messageCount: count,
            messages: messages,
            model: info["model"]?.stringValue,
            provider: info["provider"]?.stringValue,
            profileName: info["profile_name"]?.stringValue
        )
    }

    /// Map one inbound `GatewayEvent` onto the conversation domain. Returns
    /// `nil` for non-conversation handshake events (`gateway.ready` — consumed
    /// by the transport's own ready handshake, not a turn event). Unknown
    /// conversation event types are preserved as `.unknown` (spec §5.5).
    ///
    /// t_8401d3c3: the gateway-stamped per-session `seq` (`event_replay.py`)
    /// rides at the TOP level of the event params (sibling of `payload`), so
    /// it is threaded into every case for client-side continuity tracking.
    static func decodeEvent(_ event: GatewayEvent) -> ConversationEvent? {
        let sid = event.sessionID ?? ""
        let payload = event.payload?.objectValue ?? [:]
        let seq = event.seq

        switch event.type {
        case .gatewayReady:
            // Handshake only; not a conversation event.
            return nil
        case .sessionInfo:
            return .sessionInfo(
                sessionID: sid,
                model: payload["model"]?.stringValue,
                provider: payload["provider"]?.stringValue,
                title: payload["title"]?.stringValue,
                cwd: payload["cwd"]?.stringValue,
                profileName: payload["profile_name"]?.stringValue,
                // R9-T1: approval-bypass readback (server.py:7758 — the
                // effective OR of config mode / env / session flag).
                yolo: payload["yolo"]?.boolValue,
                approvalMode: payload["approval_mode"]?.stringValue,
                seq: seq
            )
        case .approvalRequest:
            // R9-T1 (server.py:3102): a dangerous command is blocked. The
            // command is ALREADY gateway-redacted (#48456); the client-side
            // second pass (`Redaction.commandPreview`) runs in the VIEW
            // MODEL before rendering, keeping the domain value raw-wire.
            // Fail-soft decode: a payload without request_id is DROPPED —
            // not surfaced as `.unknown` (that would render a confusing
            // transcript row for a known-but-malformed approval frame).
            return GatewayApprovalClient.decodeApprovalRequest(payload: event.payload, sessionID: sid)
                .map { request in
                    ConversationEvent.approvalRequested(
                        sessionID: request.sessionID,
                        requestID: request.requestID,
                        command: request.command,
                        detail: request.detail,
                        choices: request.choices,
                        seq: seq
                    )
                }
        case .messageStart:
            return .messageStart(sessionID: sid, seq: seq)
        case .messageDelta:
            return .messageDelta(
                sessionID: sid,
                text: payload["text"]?.stringValue ?? "",
                rendered: payload["rendered"]?.stringValue,
                seq: seq
            )
        case .messageInterim:
            return .messageInterim(
                sessionID: sid,
                text: payload["text"]?.stringValue ?? "",
                alreadyStreamed: payload["already_streamed"]?.boolValue ?? false,
                seq: seq
            )
        case .messageComplete:
            return .messageComplete(
                sessionID: sid,
                text: payload["text"]?.stringValue ?? "",
                status: payload["status"]?.stringValue,
                error: payload["error"]?.stringValue,
                seq: seq
            )
        case .thinkingDelta:
            return .thinkingDelta(sessionID: sid, text: payload["text"]?.stringValue ?? "", seq: seq)
        case .reasoningDelta:
            return .reasoningDelta(sessionID: sid, text: payload["text"]?.stringValue ?? "", seq: seq)
        case .reasoningAvailable:
            return .reasoningAvailable(sessionID: sid, text: payload["text"]?.stringValue ?? "", seq: seq)
        case .statusUpdate:
            return .statusUpdate(
                sessionID: sid,
                kind: payload["kind"]?.stringValue ?? "",
                text: payload["text"]?.stringValue ?? "",
                seq: seq
            )
        case .toolStart:
            return .toolStart(
                sessionID: sid,
                toolID: payload["tool_id"]?.stringValue ?? "",
                name: payload["name"]?.stringValue ?? "",
                context: payload["context"]?.stringValue,
                argsText: Self.compactJSON(payload["args"]),
                seq: seq
            )
        case .toolGenerating:
            return .toolGenerating(sessionID: sid, name: payload["name"]?.stringValue ?? "", seq: seq)
        case .toolProgress:
            return .toolProgress(
                sessionID: sid,
                toolID: payload["tool_id"]?.stringValue,
                name: payload["name"]?.stringValue,
                text: payload["text"]?.stringValue ?? payload["preview"]?.stringValue,
                seq: seq
            )
        case .toolComplete:
            return .toolComplete(
                sessionID: sid,
                toolID: payload["tool_id"]?.stringValue ?? "",
                name: payload["name"]?.stringValue ?? "",
                summary: payload["summary"]?.stringValue,
                seq: seq
            )
        case .backgroundComplete:
            return .backgroundComplete(
                sessionID: sid,
                taskID: payload["task_id"]?.stringValue,
                text: payload["text"]?.stringValue,
                seq: seq
            )
        case .usageUpdate:
            // R9-T3 (server.py:13133): mid-turn usage tick. The snapshot
            // rides at payload.usage (the _get_usage shape); a payload
            // without it is dropped fail-soft (never fatal).
            guard let usageObject = payload["usage"]?.objectValue else { return nil }
            return .usageUpdate(
                sessionID: sid,
                usage: GatewayConversationToolingClient.decodeUsage(.object(usageObject)),
                seq: seq
            )
        case .error:
            return .error(sessionID: sid, message: payload["message"]?.stringValue ?? "", seq: seq)
        case .unknown:
            return .unknown(sessionID: sid, rawType: event.rawType, seq: seq)
        }
    }

    /// The streamed event channel: maps every inbound `GatewayEvent` onto the
    /// conversation domain, dropping non-conversation handshake events and
    /// preserving unknown conversation types.
    static func eventStream(transport: GatewayWebSocketTransport) -> AsyncStream<ConversationEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await event in transport.subscribeToEvents() {
                    if let conversationEvent = decodeEvent(event) {
                        continuation.yield(conversationEvent)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compact JSON text for an optional JSON member (tool args/result), nil
    /// when absent or unencodable — never a failure.
    static func compactJSON(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONRPCCodec.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: error mapping

    /// Map JSON-RPC error codes onto the conversation vocabulary.
    static func mapRPCError(_ error: JSONRPCError) -> ConversationError {
        switch error.code {
        case 4001:
            // `_sess_nowait` rejects a runtime id the gateway no longer holds
            // (prompt.submit / session.interrupt paths) with 4001.
            return .sessionNotFound(Redaction.safeText(error.message))
        case 4007:
            // `session.resume` does its own DB lookup and reports an unknown
            // stored session with 4007 (methods_session.py). Both codes mean
            // "session gone — resume again / re-create".
            return .sessionNotFound(Redaction.safeText(error.message))
        case 4006:
            return .invalidRequest(Redaction.safeText(error.message))
        default:
            return .rpcFailed("\(Redaction.safeText(error.message)) (\(error.code))")
        }
    }

    static func mapTransportError(_ error: TransportError) -> ConversationError {
        switch error {
        case .connectionClosed(let reason):
            return .rpcFailed("connection closed: \(reason.debugDescription)")
        case .requestTimeout:
            return .rpcFailed("request timed out")
        case .invalidState(let s):
            return .rpcFailed("invalid state: \(s)")
        default:
            return .rpcFailed(Redaction.safeErrorDescription(error))
        }
    }
}
