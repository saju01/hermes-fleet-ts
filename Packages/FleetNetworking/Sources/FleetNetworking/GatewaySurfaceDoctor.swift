import Foundation
import FleetCore

/// H2 surface doctor: when an endpoint ANSWERS HTTP but the auth route is
/// missing (`POST /api/auth/ws-ticket` → 404, classified `.unsupported`),
/// ONE cheap follow-up GET `{base}/health` can tell the user WHICH Hermes
/// surface they actually hit.
///
/// The dogfood case (2026-09-07): the app was pointed at the `api_server`
/// REST port (OpenAI-compatible). That surface answers `/health` with
/// 200 + JSON `{"platform": "hermes-agent"}` while 404ing ws-ticket — the
/// endpoint IS a Hermes box, just not the chat gateway (`hermes serve`)
/// surface the app needs. The probe is read-only and non-secret: it sends
/// no credentials and classifies only the platform word in the body.
public enum GatewaySurfaceDoctor {

    /// What the `/health` probe concluded about the endpoint.
    public enum Finding: Equatable, Sendable {
        /// `/health` answered 200 with a hermes-agent JSON body: the endpoint
        /// is a Hermes server — just not the chat gateway surface.
        case hermesServer
        /// Anything else (non-200, non-JSON, no platform match, transport
        /// error): stay silent so the caller keeps its existing generic
        /// classification (fail-open — the doctor never makes things worse).
        case unknown
    }

    /// Bound on the single `/health` GET (connect + response). The endpoint
    /// already ANSWERED HTTP to be in this path, so this stays short.
    static let timeoutSeconds: TimeInterval = 5

    /// Marker appended to the classified failure detail when the doctor
    /// recognizes a Hermes REST surface. FleetUI's failure copy keys off
    /// this token — FleetUI cannot import FleetNetworking (M0 guard), so
    /// the shared constant lives in FleetCore
    /// (`GatewaySurfaceDoctorDetail.hermesServerMarker`); the detail string
    /// is the established transport (F1 "HTTP 404", P0-9 "no_cookie"
    /// markers work the same way).
    public static let hermesServerMarker = GatewaySurfaceDoctorDetail.hermesServerMarker

    /// Probe `{base}/health`. Never throws — every failure path returns
    /// `.unknown` so the caller's existing classification is untouched.
    public static func probe(baseURL: URL, urlSession: any GatewayHTTPClient = URLSession.shared) async -> Finding {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = min(request.timeoutInterval, timeoutSeconds)
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard data.count <= AuthREST.maxResponseBytes else { return .unknown }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unknown
            }
            return Self.isHermesAgent(body: data) ? .hermesServer : .unknown
        } catch {
            return .unknown
        }
    }

    /// 200 + a JSON body identifying as hermes-agent (the api_server
    /// `/health` envelope is `{"platform": "hermes-agent", ...}`). Tolerant
    /// decode: a top-level JSON object whose `platform` or `server` string
    /// names hermes-agent. HTML login pages (the WS gateway redirects
    /// unauthenticated `/health`) decode to nil → `.unknown`, which is
    /// correct — that surface is the gateway, not the REST mix-up.
    static func isHermesAgent(body: Data) -> Bool {
        struct HealthEnvelope: Decodable {
            let platform: String?
            let server: String?
        }
        guard let envelope = try? JSONDecoder().decode(HealthEnvelope.self, from: body) else {
            return false
        }
        let words = [envelope.platform, envelope.server].compactMap { $0?.lowercased() }
        return words.contains { $0.contains("hermes-agent") }
    }
}
