import Foundation
import FleetCore
import FleetNetworking
import TailscaleKit

/// nil leaves Go's default logging enabled. -1 explicitly selects logger.Discard
/// in tailscale_set_logfd, so enrollment URLs cannot reach device diagnostics.
struct TailscalePrivateLogger: LogSink {
    let logFileHandle: Int32? = -1
    func log(_ message: String) {}
}

/// The official IPN bus, without netmaps, private keys, debug logs or peer names.
actor TailscaleIPNConsumer: MessageConsumer {
    private var current = EmbeddedTailnetSnapshot(state: .starting)

    func notify(_ notify: Ipn.Notify) {
        if let state = notify.State {
            switch state {
            case .Running: current.state = .running
            case .NeedsLogin: current.state = .needsLogin
            case .NeedsMachineAuth: current.state = .needsApproval
            case .Stopped: current.state = .stopped
            case .Starting, .NoState: current.state = .starting
            case .InUseOtherUser: current.state = .failed
            @unknown default: current.state = .failed
            }
        }
        if let raw = notify.BrowseToURL {
            current.enrollmentURL = Self.enrollmentURL(raw)
        }
        if current.state == .running || current.state == .stopped {
            current.enrollmentURL = nil
        }
    }
    func error(_ error: any Error) { current = .init(state: .failed) }
    func value() -> EmbeddedTailnetSnapshot { current }
    func clearURL() { current.enrollmentURL = nil }

    static func enrollmentURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https",
              url.host == "login.tailscale.com", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path.hasPrefix("/a/") else { return nil }
        return url
    }
}

/// Native userspace tsnet integration following TailscaleKitHello/LocalAPI.
/// No Network Extension, host VPN, admin key, custom control server or exit node.
actor TailscaleKitDriver: EmbeddedNodeDriving {
    private var node: TailscaleNode?
    private var api: LocalAPIClient?
    private var processor: MessageProcessor?
    private var consumer = TailscaleIPNConsumer()

    func start() async throws {
        guard node == nil else { return }
        let directory = try Self.stateDirectory()
        let created = try TailscaleNode(config: Configuration(
            hostName: "hermes-fleet", path: directory.path, authKey: nil,
            controlURL: kDefaultControlURL, ephemeral: false), logger: TailscalePrivateLogger())
        node = created
        let api = LocalAPIClient(localNode: created, logger: nil)
        self.api = api
        consumer = TailscaleIPNConsumer()
        do {
            // Subscribe BEFORE interactive login. up() blocks pending enrollment;
            // LocalAPI WantRunning enables the same backend without blocking UI.
            processor = try await api.watchIPNBus(mask: [.initialState, .noPrivateKeys], consumer: consumer)
            try await api.editPrefs(mask: Ipn.MaskedPrefs().wantRunning(true).shieldsUp(true).routeAll(false).corpDNS(false))
        } catch {
            processor?.cancel()
            processor = nil
            self.api = nil
            node = nil
            throw EmbeddedTailnetError.notRunning
        }
    }

    func login() async throws {
        guard let api else { throw EmbeddedTailnetError.notRunning }
        await consumer.clearURL()
        try await api.startLoginInteractive()
    }

    func snapshot() async throws -> EmbeddedTailnetSnapshot {
        guard let node else { return .init(state: .stopped) }
        // In-memory LocalAPI remains usable if iOS has reclaimed the loopback
        // listener after suspension. Do not return the full status (node keys).
        struct Status: Decodable { let BackendState: String }
        let status = try JSONDecoder().decode(Status.self, from: await node.statusJSON())
        var result = await consumer.value()
        switch status.BackendState {
        case "Running": result = .init(state: .running)
        case "NeedsLogin": result.state = .needsLogin
        case "NeedsMachineAuth": result.state = .needsApproval
        case "Stopped": result = .init(state: .stopped)
        default: result.state = .starting
        }
        return result
    }

    func configuration() async throws -> URLSessionConfiguration {
        guard let node else { throw EmbeddedTailnetError.notRunning }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        // Official SDK: authenticated SOCKSv5 using username tsnet + a unique
        // in-memory secret. Preserve URL host/SNI and all system TLS validation.
        try await configuration.proxyVia(node)
        return configuration
    }

    func stop(logout: Bool) async throws {
        guard let api, let node else { return }
        defer {
            processor?.cancel()
            processor = nil
            self.api = nil
            self.node = nil
        }
        if logout {
            // SDK's LocalAPIClient.logout is internal. Use its documented LocalAPI
            // request shape rather than resetAuth (which has different semantics).
            let configuration = URLSessionConfiguration.ephemeral
            let loopback = try await configuration.proxyVia(node)
            guard let ip = loopback.ip, let port = loopback.port,
                  let url = URL(string: "http://\(ip):\(port)/localapi/v0/logout") else {
                throw EmbeddedTailnetError.notRunning
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            let credential = Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
            let session = URLSession(configuration: configuration,
                delegate: URLSessionPinningDelegate(trustHandler: nil, rejectRedirects: true), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw EmbeddedTailnetError.notRunning
            }
        } else {
            try await api.editPrefs(mask: Ipn.MaskedPrefs().wantRunning(false))
        }
        // Do NOT call SDK down() (pinned source calls tailscale_up), or close()
        // (deinit closes again). Drop the final owner; deinit is the ONLY closer.
    }

    private static func stateDirectory() throws -> URL {
        let fm = FileManager.default
        var directory = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
            .appendingPathComponent("FleetEmbeddedTailscale", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        try fm.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }
}
