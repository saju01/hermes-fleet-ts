import Foundation
import os
import FleetCore

/// R9-T2/T3/T4 — concrete `ConversationToolingProviding` over the
/// conversation transport: `model.options`, `session.usage`,
/// `session.context_breakdown`, `session.steer`, `session.title`,
/// `session.branch`.
///
/// SELECTION POLICY (sticky-local rule, enforced structurally): this client
/// has NO method that writes the model to config. A picker selection is
/// held client-side (per-device) and rides `session.create {model,
/// provider}` — the per-session override the gateway builds into the agent
/// (methods_session.py:50-53: "never a global config write, so picking a
/// model/effort for a new chat can't mutate the profile default").
/// `config.set` is deliberately absent from this type.
///
/// Wire ground truth (hermes-agent 0.21.0):
/// - `model.options` — methods_complete.py:469: params `{session_id?,
///   explicit_only?, include_unconfigured?, refresh?}` →
///   `{providers: [{slug, name, is_current, authenticated, models: [...]}],
///   model, provider}` (inventory.py:328).
/// - `session.usage` — methods_session.py:1828 → server.py:7512 `_get_usage`
///   (context fields optional, server.py:7542).
/// - `session.context_breakdown` — methods_session.py:1852 →
///   agent/context_breakdown.py:163.
/// - `session.steer` — methods_session.py:3750: `{session_id, text}` →
///   `{status, text}`.
/// - `session.title` — methods_session.py:1427: `{session_id, title}` →
///   `{pending, title}`.
/// - `session.branch` — methods_session.py:3282: `{session_id, count?,
///   name?}` → the full new-session payload (same decode as create/resume).
public struct GatewayConversationToolingClient: ConversationToolingProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "conversation-tooling")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: ConversationToolingProviding

    public func modelChoices(sessionID: String?) async throws -> [ModelChoice] {
        // session_id is OPTIONAL on model.options (a picker open before any
        // session exists reads the disk-config context). Omit it entirely
        // when nil so the gateway does no per-session layering.
        var params: [String: JSONValue] = [:]
        if let sessionID {
            guard RoutingGuard.isValidSessionKey(sessionID) else {
                throw ConversationError.invalidSessionKey(
                    "session_id is not a safe session key: \(sessionID)")
            }
            params["session_id"] = .string(sessionID)
        }
        do {
            let result = try await transport.request(
                method: "model.options", params: .object(params))
            return Self.decodeModelChoices(result)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    public func usage(sessionID: String) async throws -> SessionUsageSnapshot {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey(
                "session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        do {
            let result = try await transport.request(
                method: "session.usage",
                params: .object(["session_id": .string(sessionID)]))
            return Self.decodeUsage(result)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    public func contextBreakdown(sessionID: String) async throws -> ContextBreakdown {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey(
                "session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        do {
            let result = try await transport.request(
                method: "session.context_breakdown",
                params: .object(["session_id": .string(sessionID)]))
            return Self.decodeBreakdown(result)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    public func steer(sessionID: String, text: String) async throws -> Bool {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey(
                "session_id is not a safe session key: \(sessionID)")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConversationError.invalidRequest("steer text is required")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        // EXACTLY the two documented params (methods_session.py:3766-3768).
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "text": .string(trimmed),
        ])
        do {
            let result = try await transport.request(method: "session.steer", params: params)
            let queued = result["status"]?.stringValue == "queued"
            Self.log.info(
                "session.steer queued=\(queued, privacy: .public)")
            return queued
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    public func renameSession(sessionID: String, title: String) async throws -> String {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey(
                "session_id is not a safe session key: \(sessionID)")
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConversationError.invalidRequest("title required")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "title": .string(trimmed),
        ])
        do {
            let result = try await transport.request(method: "session.title", params: params)
            // 4021 shape guard: the gateway rejects an empty title; the
            // resolved title echoes otherwise.
            guard let resolved = result["title"]?.stringValue, !resolved.isEmpty else {
                throw ConversationError.malformedPayload("session.title result missing 'title'")
            }
            return resolved
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    public func branchSession(sessionID: String, name: String?) async throws -> ConversationSession {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey(
                "session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            let result = try await transport.request(method: "session.branch", params: .object(params))
            // Same projection as session.create/resume (methods_session.py:3497-3505).
            return try GatewayConversationClient.decodeSession(result)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: decoding (wire → domain)

    /// `model.options` → flat, stable-ordered `[ModelChoice]`.
    static func decodeModelChoices(_ result: JSONValue) -> [ModelChoice] {
        let currentModel = result["model"]?.stringValue ?? ""
        let currentProvider = result["provider"]?.stringValue ?? ""
        let providers = result["providers"]?.arrayValue ?? []
        var choices: [ModelChoice] = []
        for provider in providers {
            guard let o = provider.objectValue,
                  let slug = o["slug"]?.stringValue, !slug.isEmpty else { continue }
            let name = o["name"]?.stringValue ?? slug
            let isCurrentRow = o["is_current"]?.boolValue ?? false
            let models = o["models"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let capabilities = o["capabilities"]?.objectValue ?? [:]
            for model in models where !model.isEmpty {
                // "Current" needs BOTH the provider row to be current AND the
                // payload's active model to match — an unconfigured-but-
                // current row with an empty `model` marks nothing.
                let isCurrent = isCurrentRow && (currentProvider.isEmpty || slug == currentProvider)
                    && (currentModel.isEmpty ? false : model == currentModel)
                choices.append(
                    ModelChoice(
                        model: model, provider: slug, providerName: name, isCurrent: isCurrent,
                        supportsReasoning: capabilities[model]?["reasoning"]?.boolValue,
                        canDisableReasoning: capabilities[model]?["can_disable_reasoning"]?.boolValue))
            }
        }
        return choices
    }

    /// `session.usage` RPC result / streamed `usage` payload → snapshot.
    /// The context fields are OPTIONAL (server.py:7542) — absent stays nil
    /// (unknown), never a fabricated 0.
    static func decodeUsage(_ result: JSONValue) -> SessionUsageSnapshot {
        let o = result.objectValue ?? [:]
        func int(_ key: String) -> Int { o[key]?.numberValue.map(Int.init) ?? 0 }
        return SessionUsageSnapshot(
            model: o["model"]?.stringValue,
            input: int("input"),
            output: int("output"),
            total: int("total"),
            calls: int("calls"),
            contextUsed: o["context_used"]?.numberValue.map(Int.init),
            contextMax: o["context_max"]?.numberValue.map(Int.init),
            contextPercent: o["context_percent"]?.numberValue.map(Int.init)
        )
    }

    /// `session.context_breakdown` → domain (server omits zero-token
    /// categories; empty stays empty).
    static func decodeBreakdown(_ result: JSONValue) -> ContextBreakdown {
        let o = result.objectValue ?? [:]
        let categories = o["categories"]?.arrayValue?.compactMap { row -> ContextBreakdownCategory? in
            guard let co = row.objectValue,
                  let id = co["id"]?.stringValue, !id.isEmpty else { return nil }
            return ContextBreakdownCategory(
                id: id,
                label: co["label"]?.stringValue ?? id,
                tokens: co["tokens"]?.numberValue.map(Int.init) ?? 0
            )
        } ?? []
        return ContextBreakdown(
            categories: categories,
            contextMax: o["context_max"]?.numberValue.map(Int.init) ?? 0,
            contextPercent: o["context_percent"]?.numberValue.map(Int.init) ?? 0,
            contextUsed: o["context_used"]?.numberValue.map(Int.init) ?? 0,
            estimatedTotal: o["estimated_total"]?.numberValue.map(Int.init) ?? 0,
            model: o["model"]?.stringValue ?? ""
        )
    }

    // MARK: error mapping (mirrors GatewayApprovalClient)

    static func mapError(_ error: JSONRPCError) -> ConversationError {
        switch error.code {
        case 4001, 4007:
            return .sessionNotFound(Redaction.safeText(error.message))
        case 4006, 4002, 4021, 4022:
            return .invalidRequest(Redaction.safeText(error.message))
        case 4008:
            // session.branch: "nothing to branch — send a message first".
            return .invalidRequest(Redaction.safeText(error.message))
        case 4010:
            // session.steer: "agent does not support steer".
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
