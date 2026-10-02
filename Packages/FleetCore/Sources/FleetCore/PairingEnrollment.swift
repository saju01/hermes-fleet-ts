import Foundation

public enum FleetPairingError: Error, Sendable, Equatable {
    case rejected, cancelled, timedOut, unavailable, connectionUnverified, cleanupRequired
}

/// Private QR material for the server's EXISTING authentication strategy.
/// A reusable password/token makes this QR reusable too; no grant or fake TTL.
/// Never encode, log, or display this value as raw credential material.
public struct PairingEnrollment: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let origin: URL
    public let name: String
    public let strategy: GatewayAuthConfiguration.Strategy
    public let credential: GatewayCredential
    public var description: String { "PairingEnrollment(<redacted>)" }
    public var debugDescription: String { description }

    private struct Wire: Decodable {
        struct Auth: Decodable {
            let strategy: String
            let username: String?
            let password: String?
            let token: String?
        }
        let v: Int
        let kind: String
        let url: String
        let name: String?
        let transport: String
        let auth: Auth
    }

    public static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 16384, let data = text.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.v == 2, wire.kind == "hermes-fleet-ts", wire.transport == "embeddedTailscale",
              let origin = URL(string: wire.url) else { throw PairingPayload.DecodeError.unsupportedVersion(2) }
        let keys: Set<String> = ["v", "kind", "url", "name", "transport", "auth"]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: keys), let auth = object["auth"] as? [String: Any],
              origin.scheme == "https", origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/",
              let host = origin.host, host.hasSuffix(".ts.net"), host.utf8.count <= 253,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
              }),
              (1...65535).contains(origin.port ?? 443),
              (wire.name?.utf8.count ?? 1) > 0, (wire.name?.utf8.count ?? 0) <= 128 else {
            throw PairingPayload.DecodeError.notAPairingPayload
        }
        let strategy: GatewayAuthConfiguration.Strategy
        let credential: GatewayCredential
        switch wire.auth.strategy {
        case "usernamePassword":
            guard Set(auth.keys) == ["strategy", "username", "password"],
                  let username = wire.auth.username, (1...256).contains(username.utf8.count),
                  let password = wire.auth.password, (1...4096).contains(password.utf8.count) else {
                throw PairingPayload.DecodeError.notAPairingPayload
            }
            strategy = .usernamePassword
            credential = GatewayCredential(rawValue: password, username: username)
        case "sessionToken":
            guard Set(auth.keys) == ["strategy", "token"],
                  let token = wire.auth.token, (1...4096).contains(token.utf8.count),
                  !token.hasPrefix("tskey-"), !token.contains(where: { $0.isWhitespace }) else {
                throw PairingPayload.DecodeError.notAPairingPayload
            }
            strategy = .sessionToken
            credential = GatewayCredential(rawValue: token)
        default: throw PairingPayload.DecodeError.notAPairingPayload
        }
        return Self(origin: origin, name: wire.name ?? host, strategy: strategy, credential: credential)
    }
}
