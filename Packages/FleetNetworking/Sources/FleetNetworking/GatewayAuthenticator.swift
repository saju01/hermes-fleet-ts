import Foundation
import FleetCore

/// Concrete `AuthenticationProviding` for a registered gateway (v0 concrete
/// of synthesis §11 / spec §16):
///
/// - `.sessionToken` / `.bearerToken` strategy → mint a single-use 30s WS
///   ticket via `WSTicketMinting` (`POST /api/auth/ws-ticket`), enforce the
///   client-side TTL, and return `.ticket(StoredToken)` → `?ticket=`. When no
///   minter is injected, one is built from the stored credential (read from
///   the SAME `CredentialStoring` the U2 UI writes via `saveCredential`), so
///   the credential is actually sent as `X-Hermes-Session-Token` on the mint.
/// - `.usernamePassword` strategy → load the stored username+password,
///   exchange them for a session cookie via `POST /auth/password-login`
///   (`PasswordLoginClient`), then mint a single-use ticket with that cookie
///   → `?ticket=` (P3 LAN-gateway flow).
/// - `.loopbackToken` strategy → load the stored credential from
///   `CredentialStoring` (Keychain) and return `.loopbackToken(StoredToken)`
///   → `?token=`.
/// - `.none` → `.none` (no auth query).
///
/// Safety (spec §16/§29): the provider never logs or echoes the raw ticket or
/// token — `ConnectionAuthentication` redacts its printable representation and
/// is not Codable, so auth material can never reach logs, cache, or UI.
public struct GatewayAuthenticator: AuthenticationProviding {
    /// The gateway this provider authenticates for (credential lookup is
    /// per-peer in the credential store).
    public let gatewayID: GatewayID
    /// The gateway's authentication strategy.
    public let strategy: GatewayAuthConfiguration.Strategy
    /// Mints single-use WS tickets (session-token/bearer strategy). When nil,
    /// a client is built from the stored credential + base URL.
    private let ticketMinter: (any WSTicketMinting)?
    /// Loads stored credentials from Keychain (loopback + session-token
    /// strategies) — the SAME store the U2 UI writes via `saveCredential`.
    private let credentialStore: (any CredentialStoring)?
    /// Base URL used to build the ticket minter when none is injected.
    private let baseURL: URL?
    /// URLSession forwarded to the built `WSTicketClient` (testable injection;
    /// defaults to `.shared`).
    private let urlSession: any GatewayHTTPClient
    /// Shared per-gateway session-cookie ownership. Nil preserves the
    /// legacy per-call login behavior for isolated test/scripted graphs.
    private let sessionStore: (any GatewaySessionLeasing)?

    public protocol GatewaySessionLeasing: Sendable {
        func lease(
            gatewayID: GatewayID,
            login: @escaping @Sendable () async throws -> SessionCookie
        ) async throws -> SessionCookie
        func invalidate(gatewayID: GatewayID) async
    }

    public init(
        gatewayID: GatewayID,
        strategy: GatewayAuthConfiguration.Strategy,
        ticketMinter: (any WSTicketMinting)? = nil,
        credentialStore: (any CredentialStoring)? = nil,
        baseURL: URL? = nil,
        urlSession: any GatewayHTTPClient = URLSession.shared,
        sessionStore: (any GatewaySessionLeasing)? = nil
    ) {
        self.gatewayID = gatewayID
        self.strategy = strategy
        self.ticketMinter = ticketMinter
        self.credentialStore = credentialStore
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.sessionStore = sessionStore
    }

    public func authenticate() async throws -> ConnectionAuthentication {
        switch strategy {
        case .none:
            return .none
        case .loopbackToken:
            guard let credentialStore else {
                throw AuthenticationError.notConfigured
            }
            guard let credential = try await credentialStore.loadCredential(for: gatewayID) else {
                throw AuthenticationError.missingLoopbackToken
            }
            return .loopbackToken(StoredToken(rawValue: credential.rawValue))
        case .sessionToken, .bearerToken:
            guard let minter = try await makeTicketMinter() else {
                throw AuthenticationError.notConfigured
            }
            let ticket = try await minter.mintTicket()
            // Single-use + 30s TTL (synthesis §11): never connect with a
            // stale ticket — re-mint instead.
            guard !ticket.isExpired() else {
                throw AuthenticationError.ticketExpired
            }
            return .ticket(StoredToken(rawValue: ticket.token))
        case .usernamePassword:
            // P3 LAN-gateway username/password flow: load the stored
            // username+password, exchange it for a session cookie via
            // POST /auth/password-login, then mint a single-use WS ticket with
            // that cookie (POST /api/auth/ws-ticket) → ?ticket=.
            guard let credentialStore else {
                throw AuthenticationError.notConfigured
            }
            guard let baseURL else {
                throw AuthenticationError.notConfigured
            }
            guard let credential = try await credentialStore.loadCredential(for: gatewayID) else {
                throw AuthenticationError.missingLoopbackToken
            }
            guard let username = credential.username else {
                throw AuthenticationError.missingUsername
            }
            let loginClient = PasswordLoginClient(baseURL: baseURL, urlSession: urlSession)

            func mint(cookie: SessionCookie) async throws -> ConnectionAuthentication {
                let ticket = try await WSTicketClient(
                    baseURL: baseURL,
                    sessionCookie: cookie,
                    urlSession: urlSession
                ).mintTicket()
                guard !ticket.isExpired() else { throw AuthenticationError.ticketExpired }
                return .ticket(StoredToken(rawValue: ticket.token))
            }

            guard let sessionStore else {
                let cookie = try await loginClient.login(
                    username: username, password: credential.rawValue)
                return try await mint(cookie: cookie)
            }

            do {
                let cookie = try await sessionStore.lease(gatewayID: gatewayID) {
                    try await loginClient.login(username: username, password: credential.rawValue)
                }
                return try await mint(cookie: cookie)
            } catch let error as AuthenticationError {
                // The gateway's 401 no_cookie response means the ephemeral
                // cookie expired server-side. Re-login once, then surface a
                // second rejection rather than looping indefinitely.
                guard case .rejected(.noCookie) = error else { throw error }
                await sessionStore.invalidate(gatewayID: gatewayID)
                let freshCookie = try await sessionStore.lease(gatewayID: gatewayID) {
                    try await loginClient.login(username: username, password: credential.rawValue)
                }
                return try await mint(cookie: freshCookie)
            }
        }
    }

    /// The ticket minter for the session/bearer path: an injected minter wins
    /// (tests / explicit wiring), otherwise one is built from the stored
    /// credential so `X-Hermes-Session-Token` is actually sent on the mint.
    private func makeTicketMinter() async throws -> (any WSTicketMinting)? {
        if let ticketMinter { return ticketMinter }
        guard let credentialStore, let baseURL else { return nil }
        guard let credential = try await credentialStore.loadCredential(for: gatewayID) else {
            throw AuthenticationError.missingLoopbackToken
        }
        return WSTicketClient(baseURL: baseURL, sessionToken: credential.rawValue, urlSession: urlSession)
    }
}

/// Adapter from a plain `WSTicketMinting` to `AuthenticationProviding`, so the
/// transport's legacy `ticketMinter:` init and existing tests keep working
/// while the seam is the auth provider. Mints a single-use ticket, enforces
/// TTL, returns `.ticket`.
public struct TicketOnlyAuthenticator: AuthenticationProviding {
    private let ticketMinter: any WSTicketMinting

    public init(ticketMinter: any WSTicketMinting) {
        self.ticketMinter = ticketMinter
    }

    public func authenticate() async throws -> ConnectionAuthentication {
        let ticket = try await ticketMinter.mintTicket()
        guard !ticket.isExpired() else {
            throw AuthenticationError.ticketExpired
        }
        return .ticket(StoredToken(rawValue: ticket.token))
    }
}
