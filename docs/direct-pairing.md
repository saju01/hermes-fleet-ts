# Direct private pairing (QR v2)

Fleet's offline Mac generator prepares a QR containing **an existing Hermes
credential** and selects **embedded Tailscale**. It does not create a server,
listener, broker, port, service, account, API key, authentication grant, or
Tailscale identity. It changes no server authentication, routes, ACLs or TLS trust.

## Open the private form on the Mac

From the Fleet repository on your Mac:

```sh
./scripts/fleet-pairing-qr
```

An agent may prepare **nonsecret** details for a selected, existing gateway:

```sh
./scripts/fleet-pairing-qr \
  --url 'https://gateway.example.ts.net' \
  --name 'My Hermes' \
  --username 'operator'
```

These are examples, not a provisioned gateway/account. Never put a password,
session token, grant, Tailscale auth key, or URL containing secrets in a command,
chat, tool argument, environment variable, or script. The launcher accepts only
these nonsecret fields, `--prepare-only`, and help; it never reads credentials
from arguments or stdin. Invalid arguments are rejected without repeating them.
Do not misuse the display-name or username flags to carry secrets.

The launcher uses Python 3 (no Python packages) and macOS `open` to open a
self-contained local HTML file in your default browser. If Python 3 is not already
available, install it through your normal approved Mac tooling. The generator
needs no Node, npm, network access, browser installation, or web server at runtime.
`--prepare-only` creates the private file without opening it and outputs **only its
nonsecret path**, never a payload. File URLs contain no prefill query or fragment.

1. Confirm the exact HTTPS `*.ts.net` origin belongs to your existing gateway.
   The origin may retain a nondefault port; no new port is added. A trailing root
   slash, hostname case and explicit default `:443` are normalized to the same
   HTTPS origin. Userinfo, paths, query/fragment (including empty `?`/`#`), invalid
   DNS labels, ambiguous ports, and URL-parser repairs are rejected.
2. Select a credential **already valid for that gateway**. Prefer a scoped,
   revocable credential only where the gateway genuinely supports it. Otherwise
   use the existing Hermes username/password. The alternative session-token
   option is only for a gateway that already supports that native authentication;
   do not substitute an API key, another app's cookie or Tailscale key.
3. Enter the password/token **locally in the masked field**, or use your local
   password manager's secure UI if it supports local files. Do not send it to an
   assistant. The tool cannot verify credentials offline, reverse a password
   hash, reset a password, mint a grant, or prove token support.
4. Acknowledge the warning and display the QR privately. Scan it in Fleet. The app
   establishes its embedded Tailscale path (official sign-in/device approval may
   still require you), then uses the credential through existing Hermes login.
5. Click **Clear all & hide QR** and close the tab after scanning. The QR also
   disappears when any form field changes. Hiding/leaving the tab clears all
   current form values and QR pixels; password/token fields clear immediately
   after each display attempt, including failure.

**A reusable credential makes a reusable QR.** This is not one-time, not
device-bound and has no generator-enforced TTL. Clearing the screen is not
revocation. Anyone who captures it may reuse that credential according to the
server's access rules. If exposed, revoke/rotate it through the existing server's
supported controls. A future one-time/device-bound flow would require a verified
server-issued authorization mechanism; this offline tool cannot supply one.

## Privacy boundary

The output lives under
`~/Library/Application Support/HermesFleet/pairing-qr/pairing-*/index.html`.
Directories are private (`0700`), the file is `0600`; unsafe ownership, writable
ancestors and symlinks in the app path are rejected. The generated file contains
only public program code plus nonsecret prefill. Entered credentials and the QR
exist only at runtime in the browser. Old generated files retain their original
nonsecret prefill; delete those exact `pairing-*` directories when no longer
needed. Clearing the form does not rewrite static prefill.

The form has no fetch, WebSocket, storage, cookie, service worker, analytics,
logging, clipboard, download or export path. The bundled QR library loads without
a CDN. A restrictive hash-based CSP blocks network connections, outgoing forms,
frames, workers, objects, external scripts, and unauthorized inline scripts.
Generation is refused outside a top-level local file or with a URL query/fragment.
Do not publish it to a portal or serve it over HTTP; an agent working in a private
Mac portal should open the local file on the Mac instead. A portal renderer would
need its own separately verified security boundary.

Use a trusted browser and private display, with no screen sharing or recording.
The page cannot defeat screenshots, a malicious extension, browser debugging,
other processes running as your Mac user, OS memory/swap, or the browser's own
password manager. JavaScript drops references and clears canvas/input state but
cannot promise cryptographic memory erasure. Print styling hides the page; it is
not screenshot protection. Browser history may retain the nonsecret file path.
Never photograph, attach, commit, or publish a real credential QR.

## Wire contract

Generator output is JSON with exactly these fields (synthetic example only):

```json
{"v":2,"kind":"hermes-fleet-ts","url":"https://gateway.example.ts.net","name":"My Hermes","transport":"embeddedTailscale","auth":{"strategy":"usernamePassword","username":"operator","password":"fixture-only-not-a-real-password"}}
```

Alternatively, `auth` is exactly:

```json
{"strategy":"sessionToken","token":"fixture-only-not-a-real-session"}
```

Unknown versions/kinds/transports, extra fields, mixed credential types and empty
required fields are rejected without downgrade. Password/token contents and
Unicode are preserved, not trimmed. Controls and malformed Unicode are rejected;
session tokens also reject whitespace and the Tailscale `tskey-` prefix, matching
the native decoder. Limits: name 128 UTF-8 bytes, username 256 UTF-8 bytes,
password/token 1024 UTF-16 code units, input URL 2048 code units; the final
serialized UTF-8 QR is at most 2048 bytes. Very long valid server
credentials outside those limits are not supported. Legacy QR v1 semantics remain
the client's separate responsibility; this generator emits v2 only.

## Verification and maintenance

See [the tool README](../tools/pairing-qr/README.md) for unit, browser/render/decode,
CSP, public-safety and dependency-provenance checks. Browser tests use only
synthetic fixtures and an already available Chrome CDP endpoint; they create no
listener and use a disposable isolated browser context. QR screenshots are
decoded in memory, never saved. They do not prove physical-phone acceptance or
real gateway authentication; those remain separate client/backend tests.
