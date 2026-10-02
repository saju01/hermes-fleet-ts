# Offline Fleet pairing QR

Run `./scripts/fleet-pairing-qr` from the repository root on a Mac. See
[direct pairing](../../docs/direct-pairing.md) for the workflow and privacy limits.
`page.html` is a source template, not the launchable file. The launcher assembles
hash-authorized inline JS/CSS into a private self-contained file; no runtime
package install, server, localhost listener or CDN is involved.

## Tests

From the repository root (Python 3 and Node 18+ for tests):

```sh
node --test tools/pairing-qr/tests/core.test.cjs
python3 tools/pairing-qr/tests/launcher_test.py
python3 tools/pairing-qr/tests/audit_test.py
bash scripts/public_safety_guard.sh
```

The existing public guard covers tracked files only; `audit_test.py` additionally
scans the new scoped files, even before they are tracked.

For actual browser rendering and independent PNG QR decoding, use an **existing**
Mac Chrome automation CDP endpoint bound to loopback. Do not alter a personal
profile, expose CDP, or install a browser globally. Prepare test-only dependencies
outside the repository if unavailable:

```sh
export FLEET_QR_TEST_DIR="$HOME/.cache/fleet-pairing-qr-tests"
mkdir -p "$FLEET_QR_TEST_DIR"
npm install --prefix "$FLEET_QR_TEST_DIR/test-deps" --ignore-scripts \
  --no-audit --no-fund playwright-core@1.58.2 jsqr@1.4.0 pngjs@7.0.0
export NODE_PATH="$FLEET_QR_TEST_DIR/test-deps/node_modules"
export FLEET_QR_CDP='http://127.0.0.1:9222'
node tools/pairing-qr/tests/browser.cjs
```

The harness connects directly on the Mac, creates an offline ephemeral context,
never operates on existing tabs, then closes its context and disconnects without
closing Chrome. It opens only generated fixture files. The synthetic HTTPS-hosted
refusal case is fulfilled inside Playwright interception, not by a server or
network request. Both credential variants include Unicode; actual canvas
screenshots are decoded with independent `jsqr`, compared exactly, and discarded
in memory. No real gateway or credentials are used. Deliberate CSP-negative tests
expect browser violations (remote-script attempts fail with reason `csp` before
wire I/O); ordinary pairing must produce no requests, errors or console output.

The tests cover strict schema/origin/field validation, byte limits, private file
permissions, rejected secret arguments, nonsecret HTML escaping, template-marker
injection, symlink refusal, clearing on explicit action/target edit/pagehide/tab
hiding/navigation-back/failure, and enforced CSP. A tab becoming hidden clears
state by design: keep the generator foreground while scanning.

## Bundled dependency provenance and scoped audit

- QR encoder: upstream `kazuhikoarase/qrcode-generator`, npm **1.4.4**, MIT.
- Tag `js1.4.4` resolves to commit
  `9bd2163ddc1628d1ec8ff22ea288a747275ef442`.
- `vendor/provenance.json` pins the official npm tarball's SHA-512 integrity,
  archive SHA-256 and each bundled file's SHA-256. Acquisition verified npm
  integrity and byte-for-byte equality of the two JS files against that GitHub
  commit. The package omits LICENSE, so `vendor/LICENSE` is taken directly from
  that same pinned commit. The complete license is also embedded in generated HTML.
- `vendor/qrcode.js` and `vendor/qrcode_UTF8.js` are **unmodified** upstream bytes.
  The explicit UTF-8 adapter avoids the library's legacy default byte encoding.
- Scoped review: encoder APIs used are `qrcode`, `addData`, `make`, `isDark`,
  `getModuleCount`. Source checks found no network, persistence, eval/Function,
  DOM, logging, import or require APIs in these bundled files. The encoder also
  offers unused string/image exporters; the application does not call them.
  It draws only integer black/white canvas modules with a four-module quiet zone
  and M error correction. The decoder is test-only, never bundled in the page.
- This is a scoped source/provenance review plus executable guards, **not a claim
  of an independent third-party security audit**. Pin changes need renewed review,
  official-byte verification, license review and the render/decode suite. The
  dependency has no access to the network even if a future code path tries it,
  because generated pages also enforce `connect-src 'none'` and hash-only scripts.

Do not add credential CLI flags, import/export, saved QR files, CDN scripts,
server-issued-grant claims, or persistence as convenience features.
