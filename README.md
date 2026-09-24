# Hermes Fleet TS

A fork of [AIowa-LLC/Hermes Fleet](https://github.com/AIowa-LLC/hermes-fleet), extended with **app-owned embedded Tailscale** using the official **libtailscale / TailscaleKit** SDK.

The TS integration routes gateway HTTP and WebSocket traffic through the embedded node's authenticated SOCKS proxy. It is not a wrapper around the separate Tailscale app or a device-wide VPN. The integration is being prepared for this fork; build, runtime validation, and TestFlight delivery are separate gates.

Original Hermes Fleet attribution and the MIT license are retained. Tailscale SDK and dependency licenses apply separately. The upstream project overview follows.

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent deployments. It connects directly to gateways selected by the user so fleet state, conversations, controls, and credentials stay between the phone and the user's Hermes infrastructure.

## Status

Hermes Fleet is under active development. The current project targets **iOS 26**, uses **Swift 6**, and is generated from `project.yml` with XcodeGen.

This repository contains source code and development tooling. It does not require an AIowa-hosted relay or shared operator account.

## Capabilities

Current surfaces include:

- four-tab navigation — **Fleet, Chats, Bots, Gateways** — where every screen has exactly one owning tab (see [`docs/navigation.md`](docs/navigation.md))
- **Fleet Home** — a truthful glance surface: connected/known-bot facts, known attention items, real execution activity, this phone's recent destinations, and connection summaries (coverage limits below)
- **Gateway Detail** — one cockpit per machine: identity, connection controls, current work, the machine's attention item, and its resource rows (Bots, Groups, Projects, Kanban, Schedules, Skills, Memory)
- multi-gateway registration, connection state, health, and fleet roster
- **Bot Mode**: a fleet-wide Bots roster with full bot lifecycle management (see [Bot Mode](#bot-mode) below)
- canonical Bot Chat with continuous-chat semantics, `@Bot` mentions, and Bot Routines
- hosted Group rooms, including cross-gateway rooms linked over gateway-to-gateway RoomLink
- RoomLink management: peer grants and route registration, replication/replay, and authority promotion
- streaming conversations with reconnect and replay handling
- gateway authentication and Keychain-backed credential storage
- approvals, session controls, model selection, context information, cron, and skills
- read-only Kanban visibility, memory graph, and Projects browsing
- attachments, message reactions, and on-device voice input/output

Some features depend on methods exposed by the connected Hermes gateway version. Unsupported capabilities should fail closed or remain unavailable rather than fabricate state.

### Fleet Home coverage honesty

Fleet Home's attention and activity sections are **known-items only**:

- **Needs You** lists already-observed actionable items (classified gateway failures plus attention seen in rooms this phone has opened). It is not a fleet-wide pending-action inbox — unobserved rooms contribute nothing, and incomplete coverage is labeled as such ("N known items"), never rendered as an empty inbox.
- **Active Now** shows real execution signals from roster data only. There is no fleet-wide execution telemetry; when coverage is incomplete the section says so instead of guessing.
- **Continue** is device-local: a recent-open index on this phone (at most 50 references, 30-day retention, pruned on gateway removal). It is not synchronized across devices.
- Unknown never renders as zero. A partial fleet outage is shown as partial, not as "all quiet".

## Bot Mode

Bot Mode is implemented against the Hermes gateway's `groups.*` and bot-profile surfaces. The iPhone is the **controller**; the gateways are the compute and agent plane.

- **Fleet-wide Bots roster** — every bot on every registered gateway, identified by source-qualified `(GatewayID + ProfileSlug)` identity. Bots with the same name on different gateways are never merged into one local slug.
- **Bot creation and full profile editing** — name/display name, description, model/provider configuration, SOUL file editing, Skills/Toolsets/MCP toggles, with confirm-required guards for expensive model changes.
- **Sections** — organize the roster into sections; delete returns bots to Unassigned.
- **Hidden and pinned bots** — hidden bots stay mentionable but leave the default roster view; pinned bots float to the top.
- **Avatar identity** — real avatars per bot, avatar upload and clear, and a generated-portrait workflow with preview and explicit confirmation.
- **Canonical Bot Chat** — each bot has one canonical chat. It is continuous: `/new` and `/reset` are protected and redirect to `/compact` instead of resetting context. Canonical Bot Chats are filtered out of the ordinary Chats list.
- **`@Bot` mentions** — autocomplete over the live fleet roster. Duplicate names disambiguate with a friendly gateway/device label (`@researcher-mac`, `@researcher-4090`) and only fall back to a short deterministic suffix if the qualified label still collides. A mention identifies a teammate; it does not by itself confirm remote dispatch.
- **Bot Routines** — structured schedules (interval and time-of-day) with a raw-expression escape hatch, edited through the normal profile surface.
- **Hosted Groups** — create and chat in gateway-hosted rooms (`groups.create` / `groups.send` / `groups.log`), with pending approvals, retries, stop, rename, and disband.
- **Cross-gateway Groups** — a room hosted on one gateway can link members whose bots live on another gateway. Setup is `create on home → invite on target → register on home`; the two gateways then talk **directly gateway-to-gateway** over RoomLink. The iPhone never relays room traffic and Fleet makes no background-relay claims.
- **RoomLink management** — per-room panel for capability negotiation (honest unsupported state when the gateway disables RoomLink), peer grants with explicit TTL, route registration using the target's exact advertised capability catalog, grant revocation, and peer-route status.
- **Replication and promotion** — manual replay pulls the authority's real room profile and verbatim `groups.log` pages and submits them to `groups.replicate` (idempotent; refuses sequence gaps and authority-epoch regressions). Promotion is a takeover gated behind an explicit confirmation naming the previous authority; it requires `confirm: true` and a caught-up replica.
- **Capability-gated behavior** — RoomLink compatibility is decided by the advertised `protocol_versions` list (membership, not a single version), the advertised method list, and the endpoint/transport capability. Missing, empty, or changed capability information fails closed.

### Not currently supported

- **Cross-gateway `@Bot` DM relay is not guaranteed by Fleet.** Mentioning a remote bot identifies it and passes route identity to the agent, but Fleet does not verify or relay the remote messaging route; delivery depends on gateway-side `message_agent` availability.
- RoomLink carries text only (no attachments) across gateways; the composer hides the attachment tray accordingly.
- The iPhone does not courier RoomLink traffic in the background — gateway-to-gateway linking is the gateways' own direct connection.


## Architecture

```text
FleetCore          domain models, policies, and cross-module seams
   ▲
   ├─ FleetNetworking   JSON-RPC/WebSocket transport and gateway clients
   ├─ FleetSecurity     Keychain-backed credentials, tokens, and trust pins
   ├─ FleetPersistence  SwiftData non-secret cache and snapshots
   └─ FleetUI           SwiftUI screens and view models

HermesFleetApp     composition root that wires concrete implementations
```

`FleetUI` does not import `FleetNetworking`. Transport abstractions live in `FleetCore`, and the app target is responsible for composition. See [`docs/architecture.md`](docs/architecture.md) for the current architecture and known design work.

## Requirements

- macOS with Xcode 26.x
- Swift 6 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- an iOS 26 simulator or compatible device
- [gitleaks](https://github.com/gitleaks/gitleaks) for the full repository validation gate

## Build and test

The committed Xcode project is generated output. `project.yml` is the source of truth:

1. modify `project.yml` (never hand-edit `HermesFleetApp.xcodeproj/project.pbxproj`)
2. run `xcodegen generate`
3. commit both files together

CI enforces this with a drift gate: the build fails when the committed project differs from what `xcodegen generate` produces (`bash scripts/xcodegen_drift_gate.sh` locally).

```sh
xcodegen generate
make build
make test
make test-core
make dev-check
make validate
```

`make dev-check` is the fast local development loop: static guards, a
simulator build, package tests, and the focused UI suites selected from the
working diff (see [`docs/dev-loop.md`](docs/dev-loop.md)). The authoritative
broad repository/CI validation gate is `scripts/c1_ci_validate.sh` — XcodeGen
generation and drift gate, package tests, hosted unit tests, simulator UI
suites, module-boundary enforcement, the public-safety residue guard, and
gitleaks. Run `make ci` (or the script directly) before opening a pull
request.

On GitHub, pull requests run a fast preflight — static guards, package tests,
unit tests, and a focused UI subset selected from the changed files — while
merge-queue candidates run the complete validation (all five UI shards)
against the exact queued candidate; a single `CI Gate` check summarizes the
result for each topology. Locally `make ci` runs the identical full phases in
sequence.

For the repository safety gates:

```sh
bash scripts/public_safety_guard.sh
gitleaks detect --source . --no-git
```

The GitHub Actions workflow runs the repository's C1 validation for source, project, test, and CI changes; see [`docs/dev-loop.md`](docs/dev-loop.md) for the pull-request preflight vs merge-queue split.

## Connecting a gateway

Gateway details are user-supplied. Hermes Fleet does not ship with a maintainer endpoint or shared credentials. Prefer TLS-protected endpoints, especially outside trusted local networks.

See [`docs/gateway-pairing.md`](docs/gateway-pairing.md) for manual and QR-assisted setup.

## Documentation

Start with [`docs/README.md`](docs/README.md).

- [`docs/architecture.md`](docs/architecture.md) - module boundaries, data flow, and architectural constraints
- [`docs/features.md`](docs/features.md) - current feature surfaces and important limitations
- [`docs/navigation.md`](docs/navigation.md) - four-tab structure, ownership model, and restoration
- [`docs/gateway-pairing.md`](docs/gateway-pairing.md) - gateway setup and QR pairing
- [`docs/adr/`](docs/adr/) - architectural decision records
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - development and pull request guidance
- [`SECURITY.md`](SECURITY.md) - security model and vulnerability reporting

## Security

Credentials belong in the platform Keychain, not source, logs, screenshots, fixtures, or documentation. Gateway endpoints are treated as origins and sensitive URL material is rejected or redacted at trust boundaries.

Please report vulnerabilities privately according to [`SECURITY.md`](SECURITY.md).

## License

Hermes Fleet is available under the [MIT License](LICENSE).
