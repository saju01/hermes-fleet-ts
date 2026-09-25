import Foundation
import FleetCore

/// Builds a per-gateway roster session (connectivity + roster RPCs over ONE
/// transport) for the M8 union aggregation. Injected at the composition root —
/// production builds a `SingleGatewayConnection`; tests build in-process
/// connections or scripted stubs. Mirrors M7's `GatewayConnectionFactory`.
public typealias GatewayRosterSessionFactory = @Sendable (
    _ gateway: FleetGateway,
    _ credential: GatewayCredential?
) -> any GatewayRosterSession

/// Concrete `FleetRosterProviding` — the M8 multi-gateway union roster service.
///
/// Drives one roster session per registered gateway, fetches each gateway's
/// `profiles.list`, and aggregates every bot into a union `FleetRoster` keyed
/// by full `Route` (owning gateway preserved — spec §31 Multi-Gateway).
///
/// Partial-outage contract (spec §31 / §13 / §30): gateways are refreshed
/// CONCURRENTLY and independently. A gateway that fails to connect or answer
/// is classified into the snapshot's `gatewayOutcomes` — it NEVER throws the
/// whole refresh, never blocks another gateway, and the fleet stays useful
/// partially (reachable gateways' bots are still aggregated).
///
/// The session is always torn down after its refresh, on every exit path
/// (ADR #3 from M7 — the "disconnect does not crash" acceptance, spec §31).
public actor FleetRosterService: FleetRosterProviding {
    private let registry: any GatewayRegistryManaging
    private let credentials: any CredentialStoring
    private let sessionFactory: GatewayRosterSessionFactory
    /// H2: URLSession the surface-doctor `/health` probe uses (injectable for
    /// tests; defaults to `.shared`). Read-only, non-secret GET.
    private let doctorSession: URLSession
    private let doctorSessionFactory: (@Sendable (FleetGateway) -> any GatewayHTTPClient)?
    /// FOS-4 (SPEC §17): at most this many gateways refresh concurrently.
    private let maxConcurrentGatewayRefreshes: Int
    /// FOS-4 (SPEC §17): per-gateway observation deadline. A gateway whose
    /// connect+roster cycle exceeds it settles as a classified `.offline`
    /// failure (never hangs the wave).
    private let perGatewayDeadline: TimeInterval

    public init(
        registry: any GatewayRegistryManaging,
        credentials: any CredentialStoring,
        sessionFactory: @escaping GatewayRosterSessionFactory,
        doctorSession: URLSession = .shared,
        doctorSessionFactory: (@Sendable (FleetGateway) -> any GatewayHTTPClient)? = nil,
        maxConcurrentGatewayRefreshes: Int = 3,
        perGatewayDeadline: TimeInterval = 10
    ) {
        self.registry = registry
        self.credentials = credentials
        self.sessionFactory = sessionFactory
        self.doctorSession = doctorSession
        self.doctorSessionFactory = doctorSessionFactory
        self.maxConcurrentGatewayRefreshes = max(1, maxConcurrentGatewayRefreshes)
        self.perGatewayDeadline = perGatewayDeadline
    }

    // MARK: FleetRosterProviding

    public func refreshRoster() async -> FleetRosterSnapshot {
        let gateways = await registry.allGateways()
        var roster = FleetRoster()
        var outcomes: [GatewayID: GatewayRosterOutcome] = [:]

        // Concurrent, independent per-gateway refresh. A `withTaskGroup`
        // whose children never throw (each catches + classifies its own
        // failure) is the partial-outage seam: one unreachable gateway
        // cannot cancel or poison the others' refreshes.
        //
        // FOS-4 (SPEC §17): the wave is BOUNDED — at most
        // `maxConcurrentGatewayRefreshes` gateways in flight (a sliding
        // window; new gateways start only as earlier ones settle) and each
        // gateway's whole observation cycle is fenced by
        // `perGatewayDeadline` (see `refreshGateway`). Results settle
        // independently: one timeout never holds the others hostage.
        await withTaskGroup(
            of: (GatewayID, GatewayRosterOutcome, FleetGateway, [FleetBot]).self
        ) { group in
            var inflight = 0
            var pending = gateways.makeIterator()
            let factory = sessionFactory
            let doctor = doctorSession
            let doctorFactory = doctorSessionFactory
            let deadlineFenced = perGatewayDeadline
            func startNextIfNeeded() {
                while inflight < maxConcurrentGatewayRefreshes, let gateway = pending.next() {
                    inflight += 1
                    group.addTask { [credentials, factory, doctor, deadlineFenced] in
                        await Self.refreshGateway(
                            gateway,
                            credentials: credentials,
                            sessionFactory: factory,
                            doctorSession: doctorFactory?(gateway) ?? doctor,
                            deadline: deadlineFenced
                        )
                    }
                }
            }
            startNextIfNeeded()
            for await (id, outcome, updatedGateway, bots) in group {
                inflight -= 1
                roster.upsertGateway(updatedGateway)
                for bot in bots {
                    roster.upsertBot(bot)
                }
                outcomes[id] = outcome
                startNextIfNeeded()
            }
        }

        return FleetRosterSnapshot(roster: roster, gatewayOutcomes: outcomes)
    }

    // MARK: per-gateway refresh (isolated, never throws)

    /// Refresh ONE gateway in isolation: connect → adopt ready → fetch
    /// `profiles.list` → stamp bots with owning-gateway provenance. Never
    /// throws: every path returns a classified outcome, and the session is
    /// ALWAYS torn down before returning (ADR #3).
    ///
    /// FOS-4 (SPEC §17): the whole cycle is fenced by `deadline`. On expiry
    /// the gateway settles as `.failed(.offline, "timed out")` — the bounded
    /// observation never hangs the wave — and the still-running session work
    /// is cancelled, which triggers its `disconnect()` teardown path.
    private static func refreshGateway(
        _ gateway: FleetGateway,
        credentials: any CredentialStoring,
        sessionFactory: @escaping GatewayRosterSessionFactory,
        doctorSession: any GatewayHTTPClient,
        deadline: TimeInterval
    ) async -> (GatewayID, GatewayRosterOutcome, FleetGateway, [FleetBot]) {
        let outcome: (GatewayRosterOutcome, FleetGateway, [FleetBot])
        let factory = sessionFactory
        do {
            outcome = try await withThrowingTaskGroup(
                of: (GatewayRosterOutcome, FleetGateway, [FleetBot]).self
            ) { group in
                group.addTask {
                    await Self.refreshGatewayCycle(
                        gateway,
                        credentials: credentials,
                        sessionFactory: factory,
                        doctorSession: doctorSession
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(deadline))
                    throw RosterError.notConnected
                }
                guard let first = try await group.next() else {
                    throw RosterError.notConnected
                }
                // Whichever finished first wins; cancel the loser (a raced
                // session task finishes its own teardown).
                group.cancelAll()
                return first
            }
        } catch {
            // Deadline expiry (or an unexpected group error): classify the
            // gateway offline with an honest timed-out detail.
            var updated = gateway
            updated.connectionState = .failed(GatewayStatus.offline.rawValue)
            return (gateway.id, .failed(status: .offline, detail: "timed out"), updated, [])
        }
        return (gateway.id, outcome.0, outcome.1, outcome.2)
    }

    /// The un-fenced connect → roster cycle (the body extracted from
    /// `refreshGateway` so the deadline race can wrap it).
    private static func refreshGatewayCycle(
        _ gateway: FleetGateway,
        credentials: any CredentialStoring,
        sessionFactory: GatewayRosterSessionFactory,
        doctorSession: any GatewayHTTPClient
    ) async -> (GatewayRosterOutcome, FleetGateway, [FleetBot]) {
        let credential = try? await credentials.loadCredential(for: gateway.id)
        let session = sessionFactory(gateway, credential)

        let result: (GatewayRosterOutcome, FleetGateway, [FleetBot])
        do {
            try await session.connect()
            let adopted = await session.adoptedReady()
            let profiles = try await session.fetchProfiles()
            let bots = profiles.map { FleetBot.bot(on: gateway.id, descriptor: $0) }

            var updated = gateway
            updated.connectionState = .connected
            updated.capabilities = adopted?.capabilities ?? []
            updated.replayEpoch = adopted?.replayEpoch
            updated.authConfigured = credential != nil
            result = (.loaded(profileCount: profiles.count), updated, bots)
        } catch let error as GatewayConnectivityError {
            let status = GatewayStatus(connectivityError: error)
            var detail = error.errorDescription
            // H2 surface doctor: when the endpoint ANSWERED but is not a
            // supported surface (.unsupported — ws-ticket 404'd), ONE
            // read-only GET {base}/health can name the mix-up: a Hermes
            // api_server/REST box on the wrong port. Fail-open — the doctor
            // never changes the classification, only sharpens the copy via
            // a non-secret marker the failure copy keys off.
            if status == .unsupported, let endpoint = gateway.endpoint {
                if await GatewaySurfaceDoctor.probe(baseURL: endpoint, urlSession: doctorSession) == .hermesServer {
                    detail = (detail ?? "").appending(" (\(GatewaySurfaceDoctor.hermesServerMarker))")
                }
            }
            var updated = gateway
            updated.connectionState = .failed(status.rawValue)
            result = (.failed(status: status, detail: detail), updated, [])
        } catch let error as RosterError {
            // Gateway reachable but the roster call failed: not-connected → the
            // socket dropped under us (offline); malformed/rpc failure → the
            // surface answered but is not a usable roster (degraded).
            let status: GatewayStatus = error == .notConnected ? .offline : .degraded
            var updated = gateway
            updated.connectionState = .failed(status.rawValue)
            result = (.failed(status: status, detail: error.errorDescription), updated, [])
        } catch {
            let status = GatewayStatus.offline
            var updated = gateway
            updated.connectionState = .failed(status.rawValue)
            result = (.failed(status: status, detail: Redaction.safeErrorDescription(error)), updated, [])
        }

        // ADR #3 — the probe ALWAYS tears down before returning, on every path.
        await session.disconnect()
        return (result.0, result.1, result.2)
    }
}
