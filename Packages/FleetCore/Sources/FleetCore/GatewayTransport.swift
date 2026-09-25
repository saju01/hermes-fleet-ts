import Foundation

/// Routing is independent of Hermes authentication. Never automatically downgrade
/// an embedded gateway to system networking.
public enum GatewayTransport: String, Codable, Hashable, Sendable, CaseIterable {
    case system
    case embeddedTailscale
}

public enum EmbeddedTailnetError: Error, LocalizedError, Sendable {
    case invalidEndpoint, unavailable, notRunning, invalidEnrollmentURL

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Embedded Tailscale requires an HTTPS MagicDNS name (*.ts.net). Cross-origin requests are blocked."
        case .unavailable: "Embedded Tailscale is unavailable in this build."
        case .notRunning: "Start Tailscale and complete enrollment in Settings. Check device approval and tailnet access rules if connection still fails."
        case .invalidEnrollmentURL: "Tailscale returned an unsupported enrollment address."
        }
    }
}

/// Narrow initial scope: HTTPS MagicDNS, not exit nodes, public hosts,
/// subnet routes, IP literals or alternate control servers.
public enum EmbeddedTailnetPolicy {
    public static func validateEndpoint(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.hasSuffix(".ts.net"),
              host.split(separator: ".").count >= 4,
              host.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }) else {
            throw EmbeddedTailnetError.invalidEndpoint
        }
    }

    public static func validateRequest(_ url: URL, endpoint: URL) throws {
        try validateEndpoint(endpoint)
        guard ["https", "wss"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              url.host?.lowercased() == endpoint.host?.lowercased(),
              (url.port ?? 443) == (endpoint.port ?? 443) else {
            throw EmbeddedTailnetError.invalidEndpoint
        }
    }
}
