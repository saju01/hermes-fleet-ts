import Foundation
import os
import FleetCore

/// A single session cookie captured from a `POST /auth/password-login`
/// response, replayed as the `Cookie` header on the `POST /api/auth/ws-ticket`
/// mint (P3 LAN-gateway username/password flow).
///
/// The cookie name is taken from the server's actual `Set-Cookie` (the
/// gateway emits `hermes_session_at` over plain HTTP and a `__Secure-` /
/// `__Host-` prefixed variant over HTTPS), so the client never hardcodes a
/// name — it replays exactly what the gateway issued. The value is a secret
/// (it authenticates the mint), so the printable form is redacted (spec
/// §29).
public struct SessionCookie: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// The `Cookie` header value for this single cookie.
    public var headerValue: String { "\(name)=\(value)" }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "SessionCookie(redacted)" }
}

/// Errors surfaced by `PasswordLoginClient`. Never carry secret material
/// (spec §29: no credentials in error text).
public enum PasswordLoginError: Error, Sendable, Equatable, LocalizedError {
    /// No password-capable provider is advertised by `/api/auth/providers`.
    case noPasswordProvider
    /// The login response carried no usable session cookie.
    case missingSessionCookie
    /// The `/api/auth/providers` response was not the expected shape.
    case malformedProvidersResponse
    /// The login endpoint returned a non-2xx status (detail is the bare HTTP
    /// status — non-secret).
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .noPasswordProvider:
            return "gateway advertises no username/password provider"
        case .missingSessionCookie:
            return "login succeeded but no session cookie was returned"
        case .malformedProvidersResponse:
            return "gateway providers response was malformed"
        case .httpStatus(let code):
            return "password login failed: HTTP \(code)"
        }
    }
}
/// Real REST client for the gateway's username/password session flow:
///
/// 1. `GET  /api/auth/providers` → find the first password-capable provider
///    (the LAN gateway advertises provider `basic`, display name
///    "Username & Password").
/// 2. `POST /auth/password-login` with `{provider, username, password}` →
///    on success the gateway sets the session cookie and returns
///    `{"ok": true, "next": "/"}`.
/// 3. The session cookie (access token) is captured from `Set-Cookie` and
///    returned for the caller to replay on the WS-ticket mint.
///
/// Safety: username/password live only in the request body; the cookie is a
/// secret whose printable form is redacted; errors carry no credentials.
public struct PasswordLoginClient: Sendable {
    public let baseURL: URL
    public let urlSession: any GatewayHTTPClient

    /// Non-secret diagnostics for the LAN username/password flow (no
    /// credentials ever logged — only endpoint + HTTP status).
    private static let log = Logger(subsystem: "com.aiowa.hermesfleet", category: "password-login")

    public init(baseURL: URL, urlSession: any GatewayHTTPClient = URLSession.shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    private struct ProvidersEnvelope: Codable, Sendable {
        struct Provider: Codable, Sendable {
            let name: String?
            let supports_password: Bool?
        }
        let providers: [Provider]?
    }

    /// Discover the first password-capable provider, then log in and capture
    /// the resulting session cookie. Throws `PasswordLoginError` on any
    /// non-secret failure.
    public func login(username: String, password: String) async throws -> SessionCookie {
        let provider = try await passwordProvider()
        let cookie = try await passwordLogin(provider: provider, username: username, password: password)
        return cookie
    }

    /// Find the first provider that advertises password support.
    private func passwordProvider() async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/providers"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AuthREST.bounded(&request)

        Self.log.info("password-login: GET /api/auth/providers (\(Redaction.redactedURL(self.baseURL), privacy: .public))")
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard data.count <= AuthREST.maxResponseBytes else {
                throw PasswordLoginError.malformedProvidersResponse
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Self.log.error("password-login: providers HTTP \(http.statusCode)")
                throw AuthenticationError.httpStatus(http.statusCode)
            }
            let envelope: ProvidersEnvelope
            do {
                envelope = try JSONDecoder().decode(ProvidersEnvelope.self, from: data)
            } catch {
                Self.log.error("password-login: providers malformed")
                throw PasswordLoginError.malformedProvidersResponse
            }
            guard let provider = envelope.providers?
                .compactMap({ p in p.supports_password == true ? p.name : nil })
                .first,
                !provider.isEmpty else {
                Self.log.error("password-login: no password provider")
                throw PasswordLoginError.noPasswordProvider
            }
            return provider
        } catch {
            // P1-6: log the failure without echoing the raw error description
            // (URLError descriptions can embed the full URL incl. user-info).
            Self.log.error("password-login: providers request failed (redacted)")
            throw error
        }
    }

    /// POST `/auth/password-login` and capture the session cookie from the
    /// `Set-Cookie` headers of the response.
    private func passwordLogin(provider: String, username: String, password: String) async throws -> SessionCookie {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "provider": provider,
            "username": username,
            "password": password,
        ]
        request.httpBody = try JSONEncoder().encode(body)
        AuthREST.bounded(&request)

        Self.log.info("password-login: POST /auth/password-login (\(Redaction.redactedURL(self.baseURL), privacy: .public))")
        let (data, response) = try await urlSession.data(for: request)
        guard data.count <= AuthREST.maxResponseBytes else {
            throw PasswordLoginError.malformedProvidersResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw PasswordLoginError.httpStatus(-1)
        }
        Self.log.info("password-login: login HTTP \(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            throw AuthenticationError.httpStatus(http.statusCode)
        }
        guard let cookie = Self.parseSessionCookie(from: http) else {
            throw PasswordLoginError.missingSessionCookie
        }
        return cookie
    }

    /// Extract the session cookie from a login response's `Set-Cookie`
    /// headers. Prefers the access-token cookie name the gateway issues
    /// (`hermes_session_at`, possibly `__Secure-`/`__Host-` prefixed) and
    /// falls back to the first cookie present.
    static func parseSessionCookie(from http: HTTPURLResponse) -> SessionCookie? {
        // allHeaderFields is [AnyHashable: Any]; HTTPCookie needs [String: String].
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            fields["\(key)"] = "\(value)"
        }
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: fields,
            for: http.url ?? URL(string: "http://localhost")!
        )
        guard let target = cookies.first(where: { $0.name == "hermes_session_at" }) ?? cookies.first else {
            return nil
        }
        return SessionCookie(name: target.name, value: target.value)
    }
}

// MARK: - Redaction (spec §29: no credentials in logs/UI)

extension PasswordLoginClient: CustomStringConvertible, CustomDebugStringConvertible {
    /// The client's printable form never includes credentials OR any
    /// user-info/password that may be embedded in the endpoint (P1-6).
    public var description: String { "PasswordLoginClient(baseURL: \(Redaction.redactedURL(baseURL)))" }
    public var debugDescription: String { description }
}
