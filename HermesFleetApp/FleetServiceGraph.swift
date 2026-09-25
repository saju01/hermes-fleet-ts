import Foundation
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// Builds the concrete service graph for the app composition root.
///
/// This is the ONLY place in the app target that imports FleetNetworking and
/// wires the concrete transport/registry/roster services into the observable
/// `AppEnvironment` (behind FleetCore seams). SwiftUI never imports the
/// transport module (M0 hard guard, enforced by ModuleBoundaryTests).
///
/// DEBUG builds use the scripted fleet simulator so the U1 navigation skeleton
/// is fully walkable in the simulator without a live Hermes gateway; Release
/// builds wire real Keychain + SwiftData + live transports.
@MainActor
enum FleetServiceGraph {
    /// One process-wide owner for ephemeral username/password sessions. The
    /// cookie never leaves this actor and is never persisted.
    nonisolated static let sharedSessionStore = GatewaySessionStore()
    nonisolated static let embeddedTailnet = EmbeddedNodeController(driver: TailscaleKitDriver())

    static func makeDefaultEnvironment() -> AppEnvironment {
        // FOS-4 UI-test hygiene: `HERMES_FLEET_CONTINUE_RESET=1` deletes the
        // persisted recent-open index so Continue's empty state is
        // deterministically reachable in a shared simulator container (other
        // suites' conversation/room opens persist in the same file).
        if ProcessInfo.processInfo.environment["HERMES_FLEET_CONTINUE_RESET"] == "1" {
            try? FileManager.default.removeItem(at: FleetContinueIndexStore.defaultURL())
        }
        // P0-5: the scripted fleet is for the SIMULATOR ONLY — a Debug build
        // running on a physical device is Tony's live-dogfood lane and must
        // get the REAL production graph (real Keychain + live transports).
        // The old `#if DEBUG` alone silently shipped the fake fleet to the
        // device: scripted connect was a no-op (no socket EVER opened) and a
        // user-added gateway reported a healthy-but-empty roster — the app
        // looked "Auth configured" yet never talked to the gateway.
        #if DEBUG && targetEnvironment(simulator)
        return makeSimulatorEnvironment()
        #else
        return makeProductionEnvironment()
        #endif
    }

    /// Builds the H1 app-lock controller.
    ///
    /// Provider + mode selection:
    /// - Release (no launch env): real `LocalAuthenticationBiometricAuth`
    ///   with `.followSetting` mode → the persisted toggle (default ON) gates
    ///   the UI; biometrics with automatic device-passcode fallback.
    /// - DEBUG: scripted auth driven by `HERMES_FLEET_APP_LOCK` /
    ///   `HERMES_FLEET_LOCK_AUTH` launch env so the deterministic UI suites
    ///   stay green and the H1 UI tests can force lock states deterministically.
    ///
    /// Launch-env overrides (honored in all configs so Release-only live
    /// suites can opt out):
    ///   `HERMES_FLEET_APP_LOCK` = `disabled`|`off` → never lock,
    ///                             `enabled`|`on` → always lock,
    ///                             `follow` → respect the persisted toggle.
    ///   `HERMES_FLEET_LOCK_AUTH` (DEBUG) = `success` (default), `fail`,
    ///                                       `fail-all`.
    @MainActor
    static func makeLockController() -> AppLockController {
        let env = ProcessInfo.processInfo.environment

        let mode: AppLockController.Mode
        switch env["HERMES_FLEET_APP_LOCK"] {
        case "disabled", "off", "":
            mode = .disabled
        case "enabled", "on":
            mode = .enabled
        case "follow":
            mode = .followSetting
        default:
            #if DEBUG
            // No env in DEBUG: keep the existing deterministic UI suites green
            // (they cold-launch straight into the roster). H1 UI tests opt in
            // via launch env; Release (below) enforces the persisted toggle.
            mode = .disabled
            #else
            mode = .followSetting
            #endif
        }

        // H1 test hygiene: `HERMES_FLEET_LOCK_RESET=1` clears the persisted
        // toggle so the default-ON / persistence UI tests are deterministic
        // regardless of earlier runs sharing the same simulator app container.
        if env["HERMES_FLEET_LOCK_RESET"] == "1" {
            let key = AppLockController.defaultsKey
            UserDefaults.standard.removeObject(forKey: key)
        }

        #if DEBUG
        let auth: any AppLockBiometricAuth = makeScriptedLockAuth(env)
        #else
        let auth: any AppLockBiometricAuth = LocalAuthenticationBiometricAuth()
        #endif

        return AppLockController(auth: auth, mode: mode)
    }

    #if DEBUG
    /// Scripted lock auth for deterministic H1 UI tests (DEBUG only).
    private static func makeScriptedLockAuth(
        _ env: [String: String]
    ) -> any AppLockBiometricAuth {
        switch env["HERMES_FLEET_LOCK_AUTH"] {
        case "fail":
            return ScriptedLockAuth(biometricResult: .failure, passcodeSucceeds: true)
        case "fail-all":
            return ScriptedLockAuth(biometricResult: .failure, passcodeSucceeds: false)
        default:
            return ScriptedLockAuth(biometricResult: .success, passcodeSucceeds: true)
        }
    }

    /// F3 UI-test knob (DEBUG simulator only): `HERMES_FLEET_ZERO_GATEWAYS=1`
    /// suppresses the scripted seed registrations so the app launches with an
    /// EMPTY registry — the brand-new-user empty state with the F3 onboarding
    /// CTA is then reachable in a deterministic UI test.
    nonisolated static var zeroGatewaysEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_ZERO_GATEWAYS"] == "1"
    }

    /// F4 UI-test knob (DEBUG simulator only): `HERMES_FLEET_SINGLE_GATEWAY=1`
    /// seeds exactly ONE scripted gateway so the remove-the-final-gateway →
    /// first-run-setup transition is deterministically walkable.
    nonisolated static var singleGatewayEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_SINGLE_GATEWAY"] == "1"
    }

    /// True Bots Mode UI-test knob (DEBUG simulator only):
    /// `HERMES_FLEET_BOT_CHAT_FAIL=1` makes the scripted canonical-chat
    /// lookup throw, so the fail-closed tap behavior (retryable error, no
    /// fork, no navigation) is deterministically walkable.
    nonisolated static var botChatLookupFails: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_BOT_CHAT_FAIL"] == "1"
    }

    /// Bots-presence sync UI-test knob: the workstation roster starts down
    /// and recovers only after the lifecycle connect path succeeds.
    nonisolated static var connectSyncEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_FLEET_CONNECT_SYNC"] == "1"
    }
    #endif

    // MARK: Production — real stores + live transports

    static func makeProductionEnvironment() -> AppEnvironment {
        // The U2 UI writes credentials here (saveCredential → KeychainCredentialStore)
        // and every authenticator reads from THIS SAME store, so a credential
        // entered in the UI reaches the live gateway (L1 fix: store split).
        let credentialStore = KeychainCredentialStore()
        // T3: per-gateway TLS pin store (TOFU SPKI pinning). Shared by every
        // transport the graph builds so all four connection surfaces (probe,
        // roster, lifecycle, conversation) enforce the SAME pin per gateway.
        let pinStore = KeychainPinStore()

        // P0-4: the SAME file-backed SwiftData cache that holds transcripts +
        // health stats also backs the durable gateway-record store — a
        // user-added gateway is persisted on Add and restored on launch.
        let cacheStore = makeFileBackedCache()

        let registry: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: credentialStore,
            connectionFactory: makeProbeFactory(credentialStore: credentialStore, pinStore: pinStore),
            recordStore: cacheStore,
            pinStore: pinStore
        )
        let roster: any FleetRosterProviding = FleetRosterService(
            registry: registry,
            credentials: credentialStore,
            sessionFactory: makeSessionFactory(credentialStore: credentialStore, pinStore: pinStore),
            doctorSessionFactory: { makeGatewayHTTPSession(gateway: $0, pinStore: pinStore) }
        )
        let sessionList: any SessionListProviding = GatewaySessionListService(
            registry: registry,
            credentials: credentialStore,
            sessionFactory: makeSessionFactory(credentialStore: credentialStore, pinStore: pinStore)
        )
        // The file-backed SwiftData cache doubles as the health-stats store
        // (H2): same non-secret persistence seam, one store file.
        let cache: any CacheStoring = cacheStore
        let health = GatewayHealthStatsAccumulator(store: cacheStore)

        return AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            tlsPinStore: pinStore,
            tlsApprovalStore: pinStore,
            sessionList: sessionList,
            connectionFactory: makeConnectionFactory(
                credentialStore: credentialStore, health: health, pinStore: pinStore),
            conversationFactory: makeConversationFactory(credentialStore: credentialStore, pinStore: pinStore),
            kanbanWatcherFactory: makeKanbanWatcherFactory(credentialStore: credentialStore, pinStore: pinStore),
            managementSeamFactory: makeManagementSeamFactory(credentialStore: credentialStore, pinStore: pinStore),
            learningSeamFactory: makeLearningSeamFactory(credentialStore: credentialStore, pinStore: pinStore),
            learningSnapshotStore: cacheStore,
            projectsSeamFactory: makeProjectsSeamFactory(credentialStore: credentialStore, pinStore: pinStore),
            projectsSnapshotStore: cacheStore,
            botModeChatFactory: makeBotModeChatFactory(credentialStore: credentialStore, pinStore: pinStore),
            botProfileFactory: makeBotProfileFactory(credentialStore: credentialStore, pinStore: pinStore),
            roomSourceFactory: makeRoomSourceFactory(credentialStore: credentialStore, pinStore: pinStore),
            roomCommandFactory: makeRoomCommandFactory(credentialStore: credentialStore, pinStore: pinStore),
            roomDriverStatusFactory: makeRoomDriverStatusFactory(credentialStore: credentialStore, pinStore: pinStore),
            roomLinkFactory: makeRoomLinkFactory(credentialStore: credentialStore, pinStore: pinStore),
            health: health,
            // R9-T1: the approval banner's FaceID gate rides the SAME
            // LocalAuthentication seam as the app lock (release: real
            // LAContext; DEBUG device dogfood too, since makeDefaultEnvironment
            // only scripts the SIMULATOR).
            biometrics: makeApprovalBiometrics(),
            seedRegistrations: [],
            // R10-T4: the REAL on-device voice engine (Speech framework STT +
            // AVSpeechSynthesizer TTS) — a documented client-side deviation:
            // the gateway has no client-audio upload (server.py:17334 listens
            // on the gateway's own mic), so iOS transcribes locally and
            // submits text. See docs/R10-pocket-parity-ii.md.
            voiceEngineFactory: { SpeechVoiceIO() },
            // Connection intent is deliberately non-secret, but must survive
            // process relaunch so lifecycle restoration is real in production.
            connectionIntentDefaults: UserDefaults.standard,
            gatewaySessionInvalidator: { id in
                await FleetServiceGraph.sharedSessionStore.invalidate(gatewayID: id)
            },
            gatewaySessionInvalidatorAll: {
                await FleetServiceGraph.sharedSessionStore.invalidateAll()
            },
            embeddedTailnet: embeddedTailnet
        )
    }

    /// Approval-gate biometrics. The gate must be REAL on any device build
    /// (Debug dogfood included) — a scripted-success provider would let
    /// Approve silently pass with no FaceID prompt. Scripted auth is for the
    /// DEBUG SIMULATOR only (deterministic UI tests via
    /// `HERMES_FLEET_APPROVAL_BIOMETRIC`: `success` default, `fail`,
    /// `unavailable`).
    static func makeApprovalBiometrics() -> any AppLockBiometricAuth {
        #if DEBUG && targetEnvironment(simulator)
        switch ProcessInfo.processInfo.environment["HERMES_FLEET_APPROVAL_BIOMETRIC"] {
        case "fail":
            return ScriptedLockAuth(biometricResult: .failure, passcodeSucceeds: false)
        case "unavailable":
            return ScriptedLockAuth(biometricResult: .unavailable, passcodeSucceeds: false)
        default:
            return ScriptedLockAuth(biometricResult: .success, passcodeSucceeds: true)
        }
        #else
        // Device (Debug dogfood + Release) and production: real LAContext.
        return LocalAuthenticationBiometricAuth()
        #endif
    }

    /// t_3b321b7b: real per-gateway kanban board watcher — the
    /// `KanbanEventStreamClient` over the dashboard's kanban plugin surface,
    /// authenticating through the SAME per-gateway authenticator seam (WS
    /// ticket/loopback token) plus the strategy-appropriate HTTP credential
    /// for the board fetch. `nonisolated` for the same reason as the other
    /// factory closures.
    nonisolated private static func makeKanbanWatcherFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetKanbanWatcherFactory {
        { gateway in
            // F2: no compiled loopback default. A gateway row with no
            // endpoint gets an honest not-configured stub — the UI surfaces
            // "add a gateway" instead of silently probing a phantom
            // localhost.
            guard let base = gateway.endpoint else {
                return UnconfiguredKanbanWatcher()
            }
            let urlSession = makeGatewayHTTPSession(gateway: gateway, pinStore: pinStore)
            let authenticator = makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore)
            let strategy = gateway.authConfiguration.strategy
            let httpCredential: @Sendable () async throws -> KanbanEventStreamClient.HTTPCredential = {
                switch strategy {
                case .none:
                    return .none
                case .loopbackToken, .sessionToken, .bearerToken:
                    // The stored token authenticates HTTP plugin routes via
                    // the X-Hermes-Session-Token header (loopback/legacy
                    // token path; session/bearer deployments that gate HTTP
                    // behind OAuth cookies surface as a 401 → the view's
                    // error state, honestly).
                    if let credential = try? await credentialStore.loadCredential(for: gateway.id) {
                        return .sessionTokenHeader(credential.rawValue)
                    }
                    return .none
                case .usernamePassword:
                    // Fresh login per credential resolution (matches the
                    // ticket-mint freshness discipline; snapshot fetches are
                    // infrequent).
                    guard let credential = try? await credentialStore.loadCredential(for: gateway.id),
                          let username = credential.username else {
                        throw KanbanBoardError.malformedResponse("no credential stored")
                    }
                    let cookie = try await PasswordLoginClient(baseURL: base, urlSession: urlSession).login(
                        username: username, password: credential.rawValue)
                    return .cookie(cookie)
                }
            }
            return KanbanEventStreamClient(
                gatewayID: gateway.id,
                baseURL: base,
                authenticator: authenticator,
                httpCredential: httpCredential,
                urlSession: urlSession,
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore)
            )
        }
    }

    /// Real per-gateway conversation session (U3): connectivity + M5
    /// conversation + M6 replay + M4 history over ONE transport. Mirrors the
    /// connection factory; `nonisolated` so the `@Sendable` closure can build
    /// transports off the main actor.
    nonisolated private static func makeConversationFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetConversationFactory {
        { gateway, _ in
            // F2: no compiled loopback default — see makeKanbanWatcherFactory.
            guard let base = gateway.endpoint else {
                return UnconfiguredConversationSession(gateway: gateway)
            }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayConversationSession(
                gatewayID: gateway.id,
                displayName: gateway.displayName,
                endpoint: gateway.endpoint,
                transport: transport
            )
        }
    }

    /// R9-T5/T6: real per-gateway management seam (cron + skills) — the
    /// `GatewayManagementClient` over its own authenticated transport
    /// (same construction as the conversation factory; connect happens in
    /// the pane's view model path via the shared client's transport).
    nonisolated private static func makeManagementSeamFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetManagementSeamFactory {
        { gateway in
            // F2: no compiled loopback default — see makeKanbanWatcherFactory.
            guard let base = gateway.endpoint else {
                return UnsupportedGatewayManagement()
            }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayManagementClient(gatewayID: gateway.id, transport: transport)
        }
    }

    /// True Bots Mode: real per-gateway Bot Mode chat seam — the
    /// `GatewayBotModeClient` over its own authenticated transport (same
    /// construction as the management seam factory). Slice 2: the SAME
    /// construction backs the bot-profile seam (describe/configure/create/
    /// avatar/section-registry all live on that client).
    nonisolated private static func makeBotModeChatFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetBotModeChatFactory {
        { gateway in
            guard let base = gateway.endpoint else {
                return UnsupportedBotModeChat()
            }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayBotModeClient(gatewayID: gateway.id, transport: transport)
        }
    }

    /// Slice 2: real per-gateway bot profile seam (same transport shape as
    /// the Bot Mode chat seam).
    nonisolated private static func makeBotProfileFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetBotProfileFactory {
        { gateway in
            guard let base = gateway.endpoint else {
                return UnsupportedBotProfileManagement()
            }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayBotModeClient(gatewayID: gateway.id, transport: transport)
        }
    }

    /// Slice 2: per-gateway room source — hosted (`groups.*`) + desktop
    /// legacy (default-profile ui_meta projection), best-effort union.
    nonisolated private static func makeRoomSourceFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetRoomSourceFactory {
        { gateway in
            guard let base = gateway.endpoint else {
                return EmptyRoomSource()
            }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            let client = GatewayBotModeClient(gatewayID: gateway.id, transport: transport)
            return GatewayRoomSourceAdapter(
                gatewayID: gateway.id,
                hosted: HostedRoomProvider(gatewayID: gateway.id, client: GatewayGroupsClient(gatewayID: gateway.id, transport: transport)),
                legacy: DesktopLegacyRoomProvider(gatewayID: gateway.id, transport: transport),
                profileReader: client
            )
        }
    }

    /// Slice 4: per-gateway room-command seam — `groups.*` over the shared
    /// authenticated transport, mapped to FleetCore typed failures.
    nonisolated private static func makeRoomCommandFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetRoomCommandFactory {
        { gateway in
            guard let base = gateway.endpoint else { return nil }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayRoomCommandAdapter(
                gatewayID: gateway.id,
                client: GatewayGroupsClient(gatewayID: gateway.id, transport: transport))
        }
    }

    /// Slice 4: per-gateway driver-status seam (`groups.state`).
    nonisolated private static func makeRoomDriverStatusFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetRoomDriverStatusFactory {
        { gateway in
            guard let base = gateway.endpoint else { return nil }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayRoomDriverStatusAdapter(gatewayID: gateway.id, transport: transport)
        }
    }

    /// Slice 5 (D19): real per-gateway RoomLink seam — the
    /// `GatewayRoomLinkClient` over its own authenticated transport (same
    /// construction as the driver-status seam factory).
    nonisolated private static func makeRoomLinkFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetRoomLinkFactory {
        { gateway in
            guard let base = gateway.endpoint else { return nil }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayRoomLinkAdapter(
                gatewayID: gateway.id,
                client: GatewayRoomLinkClient(gatewayID: gateway.id, transport: transport))
        }
    }

    /// R9-T7: real per-gateway learning seam (memory graph) — the
    /// `GatewayLearningClient` over its own authenticated transport (same
    /// construction as the management seam factory).
    nonisolated private static func makeLearningSeamFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetLearningSeamFactory {
        { gateway in
            // F2: no compiled loopback default — see makeKanbanWatcherFactory.
            guard let base = gateway.endpoint else {
                return UnsupportedGatewayLearning()
            }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayLearningClient(gatewayID: gateway.id, transport: transport)
        }
    }

    /// R10-T3: real per-gateway projects seam (remote file browser) —
    /// the `GatewayProjectsClient` over its own authenticated transport
    /// (same construction as the learning seam factory).
    nonisolated private static func makeProjectsSeamFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> FleetProjectsSeamFactory {
        { gateway in
            // F2: no compiled loopback default — see makeKanbanWatcherFactory.
            guard let base = gateway.endpoint else {
                return UnsupportedGatewayProjects()
            }
            let transport = GatewayWebSocketTransport(
                baseURL: base,
                authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
                sessionFactory: makeSessionFactory(gateway: gateway, pinStore: pinStore),
                configuration: .standard
            )
            return GatewayProjectsClient(gatewayID: gateway.id, transport: transport)
        }
    }

    /// Real per-gateway connection: authenticator (from the gateway's auth
    /// strategy) + WebSocket transport + single-gateway lifecycle. Feeds the
    /// H2 connection-health accumulator from the transport's health event
    /// stream (the ONLY feed point — probe/roster/conversation transports are
    /// deliberately not fed, so short-lived probes never skew uptime or the
    /// reconnect counter).
    /// `nonisolated` so the `@Sendable` factory closures can build transports
    /// off the main actor (only `AppEnvironment` construction is main-isolated).
    nonisolated private static func makeConnectionFactory(
        credentialStore: any CredentialStoring,
        health: any ConnectionHealthAccumulating,
        pinStore: any SynchronousPinStoring
    ) -> FleetConnectionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, credentialStore: credentialStore, health: health, pinStore: pinStore)
        }
    }

    /// Real probe connection used by the registry's `testConnection`.
    nonisolated private static func makeProbeFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> GatewayConnectionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore)
        }
    }

    /// Real roster session factory used by the union roster aggregation.
    nonisolated private static func makeSessionFactory(
        credentialStore: any CredentialStoring,
        pinStore: any SynchronousPinStoring
    ) -> GatewayRosterSessionFactory {
        { gateway, _ in
            makeConnection(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore)
        }
    }

    /// T3: the session factory enforcing TOFU pinning for a gateway. For
    /// https/wss endpoints the trust handler decides server-trust challenges
    /// (first use pins, later connects must match). For http/ws endpoints
    /// there is no TLS and thus no server-trust challenge — the factory is
    /// the plain one (B2's cleartext warning stays the honest signal there).
    nonisolated static func makeSessionFactory(
        gateway: FleetGateway,
        pinStore: any SynchronousPinStoring
    ) -> any WebSocketSessionFactory {
        if gateway.transport == .embeddedTailscale {
            return RoutedWebSocketSessionFactory(route: embeddedRoute(gateway: gateway, pinStore: pinStore))
        }
        let scheme = gateway.endpoint?.scheme?.lowercased() ?? "http"
        guard scheme == "https" else {
            return URLSessionWebSocketSessionFactory()
        }
        return URLSessionWebSocketSessionFactory(
            trustHandler: PinningTrustHandler(
                gatewayID: gateway.id,
                pinStore: pinStore,
                approvalStore: pinStore as? any SynchronousTLSFirstUseApprovalStoring))
    }

    /// Build the gateway-scoped URLSession used by credential-bearing REST
    /// calls. HTTPS calls receive the same per-gateway TOFU pin policy as the
    /// WebSocket session; an unpinned or changed certificate is rejected by
    /// the shared Keychain-backed pin store. HTTP remains explicitly
    /// cleartext and is handled by the endpoint warning policy.
    nonisolated static func makeGatewayHTTPSession(
        gateway: FleetGateway,
        pinStore: (any SynchronousPinStoring)?
    ) -> any GatewayHTTPClient {
        if gateway.transport == .embeddedTailscale {
            return RoutedGatewayHTTPClient(route: embeddedRoute(gateway: gateway, pinStore: pinStore))
        }
        let configuration = URLSessionConfiguration.ephemeral
        guard gateway.endpoint?.scheme?.lowercased() == "https",
              let pinStore else {
            return URLSession(configuration: configuration)
        }
        let handler = PinningTrustHandler(
            gatewayID: gateway.id,
            pinStore: pinStore,
            approvalStore: pinStore as? any SynchronousTLSFirstUseApprovalStoring)
        let delegate = URLSessionPinningDelegate(trustHandler: handler)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    nonisolated private static func embeddedRoute(gateway: FleetGateway, pinStore: (any SynchronousPinStoring)?) -> GatewaySessionRoute {
        let handler = pinStore.map { PinningTrustHandler(gatewayID: gateway.id, pinStore: $0,
            approvalStore: $0 as? any SynchronousTLSFirstUseApprovalStoring) }
        return GatewaySessionRoute(endpoint: gateway.endpoint ?? URL(string: "https://unconfigured.invalid")!, trustHandler: handler) {
            try await embeddedTailnet.configuration()
        }
    }

    nonisolated private static func makeConnection(
        gateway: FleetGateway,
        credentialStore: any CredentialStoring,
        health: (any ConnectionHealthAccumulating)? = nil,
        pinStore: (any SynchronousPinStoring)? = nil
    ) -> any GatewayRosterSession {
        // F2: no compiled loopback default. A gateway row with no endpoint
        // gets the honest not-configured roster-session stub — every caller
        // (probe, union-roster, lifecycle factories) consumes the same
        // seam, and connect()/reads fail closed with a not-configured
        // classification instead of probing a phantom localhost.
        guard let base = gateway.endpoint else {
            return UnconfiguredRosterSession(gateway: gateway)
        }
        let sessionFactory: any WebSocketSessionFactory
        if let pinStore {
            sessionFactory = makeSessionFactory(gateway: gateway, pinStore: pinStore)
        } else if gateway.transport == .embeddedTailscale {
            sessionFactory = RoutedWebSocketSessionFactory(route: embeddedRoute(gateway: gateway, pinStore: nil))
        } else {
            sessionFactory = URLSessionWebSocketSessionFactory()
        }
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            authentication: makeAuthenticator(gateway: gateway, credentialStore: credentialStore, pinStore: pinStore),
            sessionFactory: sessionFactory,
            configuration: makeTransportConfiguration()
        )
        if let health {
            // H2: feed the accumulator from this transport's lifecycle events
            // for the lifetime of the connection (the stream never finishes).
            let events = transport.subscribeToHealthEvents()
            let gatewayID = gateway.id
            Task { [health] in
                for await event in events {
                    await health.record(event, for: gatewayID)
                }
            }
        }
        return SingleGatewayConnection(
            gatewayID: gateway.id,
            displayName: gateway.displayName,
            endpoint: gateway.endpoint,
            transport: transport
        )
    }

    /// Transport knobs. `HERMES_FLEET_PING_INTERVAL_SECONDS` (any config)
    /// overrides the heartbeat interval so the H2 UI test can assert ping RTT
    /// deterministically on a short-lived connection (the current LAN relay
    /// drops sockets at ~30s; a 2s heartbeat renders RTT within seconds).
    /// Test-support knob only — never a product feature.
    nonisolated private static func makeTransportConfiguration() -> TransportConfiguration {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["HERMES_FLEET_PING_INTERVAL_SECONDS"], let seconds = Double(raw), seconds > 0 {
            return TransportConfiguration(
                pingInterval: .milliseconds(Int64(seconds * 1000)),
                livenessTiming: .standard,
                connectTimeout: .seconds(15),
                requestTimeout: .seconds(120)
            )
        }
        return .standard
    }

    /// Authenticator honoring the gateway's configured auth strategy
    /// (synthesis §11). Credentials (loopback + session tokens) are loaded
    /// from the SAME `CredentialStoring` the U2 UI writes via saveCredential,
    /// so a UI-entered credential actually authenticates against a live
    /// gateway (L1 fix: store split + dead ticket minter).
    nonisolated private static func makeAuthenticator(
        gateway: FleetGateway,
        credentialStore: any CredentialStoring,
        pinStore: (any SynchronousPinStoring)? = nil
    ) -> any AuthenticationProviding {
        let sessionStore = FleetServiceGraph.sharedSessionStore
        // F2: no compiled loopback default — a nil endpoint flows through as
        // a nil baseURL and the authenticator fails closed with
        // `.notConfigured` (never a phantom loopback mint).
        let base = gateway.endpoint
        let urlSession = makeGatewayHTTPSession(gateway: gateway, pinStore: pinStore)
        switch gateway.authConfiguration.strategy {
        case .none:
            return GatewayAuthenticator(gatewayID: gateway.id, strategy: .none, urlSession: urlSession)
        case .loopbackToken:
            return GatewayAuthenticator(
                gatewayID: gateway.id,
                strategy: .loopbackToken,
                credentialStore: credentialStore,
                urlSession: urlSession
            )
        case .sessionToken, .bearerToken:
            return GatewayAuthenticator(
                gatewayID: gateway.id,
                strategy: gateway.authConfiguration.strategy,
                credentialStore: credentialStore,
                baseURL: base,
                urlSession: urlSession
            )
        case .usernamePassword:
            return GatewayAuthenticator(
                gatewayID: gateway.id,
                strategy: .usernamePassword,
                credentialStore: credentialStore,
                baseURL: base,
                urlSession: urlSession,
                sessionStore: sessionStore
            )
        }
    }

    /// File-backed SwiftData cache in Application Support, with the store's
    /// NSFileProtectionComplete + backup-exclusion (synthesis §12). Falls back
    /// to in-memory only if the container cannot be created (cache is
    /// non-critical for U1). Also serves as the H2 health-stats store.
    private static func makeFileBackedCache() -> SwiftDataCacheStore {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let storeURL = directory
            .appendingPathComponent("HermesFleetCache", isDirectory: true)
            .appendingPathComponent("cache.store")
        return (try? SwiftDataCacheStore.makeFileBacked(storeURL: storeURL))
            ?? (try! SwiftDataCacheStore.makeInMemory())
    }
}
