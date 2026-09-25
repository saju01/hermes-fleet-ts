# Optional embedded Tailscale

Fleet can use an app-owned userspace Tailscale node instead of the system VPN.
Existing gateways decode as **Direct / System Network**. Choose **Embedded
Tailscale** explicitly in the gateway form and use an HTTPS MagicDNS address.
The endpoint host, port, TLS trust/pinning and independent Hermes authentication
are preserved. Initial scope excludes IP literals, public hosts, HTTP, subnet
routes, exit nodes and custom control planes. There is no direct fallback.

In Settings, start Tailscale, request browser sign-in and follow the official
Tailscale link. A new device may require administrator approval and a narrow ACL
grant to its intended gateways. Fleet does not change tailnet policy. Stop
revokes current HTTP/WS sessions. Logout uses the LocalAPI logout operation;
Hermes credentials remain separate. Backgrounding suspends the app-owned node;
foregrounding resumes it only if the user had started it. On cold launch, start
it explicitly again. No enrollment occurs automatically from a gateway request.

## SDK and build

The integration is based on the official [Swift README](https://github.com/tailscale/libtailscale/blob/59d4bb82744915815178e0f0776d60026a397ee7/swift/README.md),
[TailscaleKitHello](https://github.com/tailscale/libtailscale/tree/59d4bb82744915815178e0f0776d60026a397ee7/swift/Examples/TailscaleKitHello)
and source at **59d4bb82744915815178e0f0776d60026a397ee7**. It is not a system VPN
wrapper, Network Extension or emulation. The app imports and links TailscaleKit.

One reviewed privacy fix is applied: `tailscale_set_logfd(-1)` must discard
**both** backend `Logf` and `UserLogf`. The pinned SDK discards only the first,
leaving enrollment URLs eligible for stderr via tsnet's default user logger.
`scripts/tailscale-private-logging.patch` is a one-line fix;
`scripts/tailscale-privacy-test.go` reproduces it with a synthetic message,
without starting or enrolling a node. No SDK lifecycle behavior is patched.

On macOS with Xcode and Go 1.25.5 or newer on PATH:

```sh
bash scripts/tailscale-sdk.sh build "$HOME/fleet-sdk-build"
xcodegen generate
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The build directory must not exist. Alternatively install a framework produced
by that build script:

```sh
bash scripts/tailscale-sdk.sh install /path/to/TailscaleKit.xcframework
```

`Vendor/TailscaleKit.xcframework` is untracked. Its receipt records the upstream
revision, privacy-patch hash and device/simulator binary hashes. A pre-build gate
checks that receipt and rejects an unpatched/mismatched SDK. No machine-specific
paths or signing credentials belong in the project. Distribution requires a
separate signing/privacy-manifest/dependency-license review before release.

## Routing and lifecycle

- `GatewaySessionRoute` validates the exact admitted origin before acquiring a
  configuration. Missing proxy configuration, unavailable nodes and cancellation
  fail before creating a URLSession task.
- The official `URLSessionConfiguration.proxyVia(node)` installs authenticated
  SOCKSv5. Both REST and all main/Kanban WebSocket factories acquire the current
  node configuration; attachments continue over main RPC.
- The diagnostic `/health` path receives the same per-gateway route.
- All embedded redirects are denied, including same-origin redirects. Cookie
  and credential storage are not shared with system sessions. TLS/pinning is
  unchanged; there is no trust-all delegate.
- A generation lease cancels HTTP and WS sessions on stop, logout or suspension.
  Transport edits retire the old cached gateway clients before reconnecting.
- Identity resides in private, file-protected, backup-excluded Application
  Support. Auth URLs stay transient and are admitted only from the default
  official login host. SDK errors are replaced with non-secret UI failures.
- The SDK's blocking `up()` is not awaited before subscribing to IPN. Node init
  starts tsnet; LocalAPI `WantRunning` enables it without blocking enrollment.
  Do not use pinned `down()` (it calls `tailscale_up`). Do not combine explicit
  `close()` with deinit (double-close); the adapter releases its final owner.

## Validation boundaries

Package and simulator tests use synthetic gateway/auth fixtures and do not
require a real tailnet. A successful build or fixture run does not establish
physical-device enrollment, tailnet ACLs, real Hermes authentication, suspend
behavior on a phone, or TestFlight availability. Those remain separate manual
acceptance gates with the external Tailscale app disabled.
