import Foundation

/// Agent setup prompt shown from Settings ▸ Set Up Another Server and from
/// the first-run onboarding gate (zero configured gateways).
///
/// Versioned Fleet TS mission: private native-auth pairing through the
/// Fleet-owned embedded network. The display client and selected backend are
/// distinct; no deployment-specific identifiers or credentials belong here.
public enum OnboardingPrompt {

    /// Revision 6 uses existing native Hermes auth after embedded tailnet readiness.
    public static let version: Int = 6

    /// Full copyable setup prompt; both app surfaces use this same value.
    public static let text: String = """
        I'm setting up Hermes Fleet TS with my existing connected/selected Hermes \
        gateway. Confirm the selected gateway. My Mac/private portal is only the \
        trusted display; keep a remote-UI-only client remote — never install or \
        start a backend on my Mac.

        If this arrives via Telegram or another chat, stop: tell me to paste this \
        same prompt into Hermes on my Mac or private portal. Never return a URL plus \
        password, never post a secret QR in chat, and don't ask me to manually \
        configure fields. Never ask for secrets in chat.

        1. Inspect first: detect the selected backend's operating system, Hermes \
        version, gateway/server interface, auth, and network. Preserve working \
        configuration, existing passwords, routes, firewalls, and ACLs; don't \
        reinstall. Ask which existing gateway if ambiguous, where to display the \
        private QR, or about tailnet/node enrollment only if not discoverable: \
        one decision at a time, no long questionnaire.
        2. Reuse the existing HTTPS endpoint. No new broker, port, listener, backend \
        plugin, restart, or route/ACL changes are needed. Check current documentation \
        and installed code: setup capability means standard login support, not a \
        proprietary pairing endpoint. Prefer identity-only auth only when actual \
        Hermes support is verified; reachability alone is insufficient. Otherwise \
        use a supported existing session token or username/password; don't invent \
        endpoints or credentials or require server-issued grants.
        3. My iPhone must reach the gateway securely. The recommended/default is \
        Fleet-owned embedded Tailscale, not the system VPN, with automatic transport \
        selection. Confirm alternatives only if I request them; no silent system-VPN \
        fallback. Guide official browser sign-in/device approval only if needed. \
        Don't enroll me in any new third-party service or create public exposure.
        4. Prefer scoped, revocable credentials with least privilege where supported; \
        otherwise use the existing login. Prefer single-use/device-locked pairing \
        only if the existing endpoint genuinely supports it; offline rendering \
        cannot enforce it; otherwise retain the existing login flow. Use a protected \
        local form and bundled/offline QR renderer: no extra service, no network \
        transmission or browser storage. Explain, then locally display the private \
        QR: A reusable credential QR is reusable, not single-use or automatically \
        expiring. No universal Tailscale admin keys or another app's node state. \
        No credentials/QRs in model context, logs, source control, terminal output, \
        screenshots, analytics, or clipboard exports; don't overwrite unrelated secrets.
        5. Scan in Fleet: the QR automatically fills Fleet's Authentication section \
        and selects embedded transport. Fleet waits for real Tailscale readiness, \
        then automatically performs native Hermes login and the authenticated \
        WebSocket handshake: no additional auth action or credential entry, no \
        separate Hermes password to type. Wrong or revoked credentials may require \
        correction; don't loop or bypass auth. Clear pending credentials on \
        cancel/failure/completion; save successful login in Keychain.
        6. Preserve exact-origin routing and TLS verification; never silently change \
        trust. Verify end-to-end: authenticated HTTP and authenticated WebSocket on \
        the same network path my phone will use, not just a local process check. \
        Report verified status, transport, blockers, and phone-side checks still pending.

        Fleet TS is already installed on my phone — don't try to install or update \
        the iPhone app.
        """

    /// Required mission legs; independent tests also guard ordering and unsafe fallbacks.
    public static let missionKeywords: [[String]] = [
        ["detect", "operating system", "existing connected/selected Hermes gateway"],
        ["Preserve working configuration", "existing passwords", "ACLs"],
        ["supported", "documentation", "standard login support"],
        ["Fleet-owned embedded Tailscale", "automatic transport selection"],
        ["scoped", "least privilege", "existing session token or username/password"],
        ["authenticated HTTP", "authenticated WebSocket"],
        ["private QR", "no separate Hermes password", "reusable credential QR is reusable"],
    ]

    /// Substrings that must never appear in the prompt: no credentials,
    /// private/loopback IP literals, or credential-shaped key/value text.
    public static let forbiddenSubstrings: [String] = [
        "http://",
        "100.100.",
        "192.168.", "10.", "127.0.0.1",
        "password:", "token:",
    ]

    /// Deployment-specific assumptions remain forbidden. Mac/private portal is
    /// the requested display surface and Tailscale is the Fleet TS product transport,
    /// not an assumption about the backend operating system or a user account.
    public static let forbiddenAssumptions: [String] = [
        "sideload", "Wi-Fi", "TestFlight", "macOS", "Windows",
        "Linux", "Xcode", "Homebrew", "systemd",
        "launchd", "PowerShell", "Cloudflare", "dogfood", "Tony",
        "Apple Squad",
    ]

    /// Word count used by the conciseness test.
    public static var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Mechanical hygiene check exercised by tests.
    public static func containsNoSecrets() -> Bool {
        forbiddenSubstrings.allSatisfy { !text.contains($0) }
    }

    /// No backend OS, distribution channel, or private deployment is assumed.
    public static func containsNoEnvironmentAssumptions() -> Bool {
        forbiddenAssumptions.allSatisfy { !text.contains($0) }
    }
}
