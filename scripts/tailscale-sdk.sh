#!/bin/bash
# Build the official SDK plus the reviewed private-logging fix, or install a
# previously built XCFramework. Never place SDK source or state in the app repo.
set -euo pipefail
PIN=59d4bb82744915815178e0f0776d60026a397ee7
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
if [[ "$MODE" == "build" ]]; then
    : "${2:?Usage: bash scripts/tailscale-sdk.sh build /absolute/isolated-build-directory}"
    WORK="$2"
    [[ "$WORK" = /* && ! -e "$WORK" ]] || { printf 'Use a new absolute build directory.\n' >&2; exit 1; }
    command -v go >/dev/null
    command -v xcodebuild >/dev/null
    mkdir -p "$WORK/tmp" "$WORK/cache"
    export TMPDIR="$WORK/tmp" GOPATH="$WORK/cache/go" GOMODCACHE="$WORK/cache/mod" GOCACHE="$WORK/cache/build"
    export GOMAXPROCS=4 GOFLAGS='-p=4'
    git clone https://github.com/tailscale/libtailscale.git "$WORK/libtailscale"
    git -C "$WORK/libtailscale" checkout --detach "$PIN"
    cd "$WORK/libtailscale"
    git apply "$REPO/scripts/tailscale-private-logging.patch"
    cp "$REPO/scripts/tailscale-privacy-test.go" privacy_test.go
    go test -run TestDisabledLogsDoNotEmitUserAuthMessages -count=1
    make c-archive-ios
    (cd swift && xcodebuild build -scheme 'TailscaleKit (iOS)' -derivedDataPath "$WORK/derived" -configuration Release -destination 'generic/platform=iOS' -jobs 4 CODE_SIGNING_ALLOWED=NO)
    make c-archive-ios-sim
    (cd swift && xcodebuild build -scheme 'TailscaleKit (Simulator)' -derivedDataPath "$WORK/derived" -configuration Release -destination 'generic/platform=iOS Simulator' -jobs 4 CODE_SIGNING_ALLOWED=NO)
    xcodebuild -create-xcframework \
        -framework "$WORK/derived/Build/Products/Release-iphoneos/TailscaleKit.framework" \
        -framework "$WORK/derived/Build/Products/Release-iphonesimulator/TailscaleKit.framework" \
        -output "$WORK/TailscaleKit.xcframework"
    SOURCE="$WORK/TailscaleKit.xcframework"
    python3 - "$SOURCE" "$PIN" "$REPO/scripts/tailscale-private-logging.patch" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
receipt = {'revision': sys.argv[2], 'privacyPatchSHA256': hashlib.sha256(pathlib.Path(sys.argv[3]).read_bytes()).hexdigest(),
           'binaries': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('*/TailscaleKit.framework/TailscaleKit')}}
(root / 'FleetSDK.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
elif [[ "$MODE" == "install" ]]; then
    SOURCE="${2:?Usage: bash scripts/tailscale-sdk.sh install /path/to/TailscaleKit.xcframework}"
else
    printf 'Usage: tailscale-sdk.sh build NEW_ABSOLUTE_DIR | install XCFRAMEWORK\n' >&2
    exit 1
fi
python3 - "$SOURCE" "$REPO/Vendor/TailscaleKit.xcframework" "$REPO/scripts/tailscale-private-logging.patch" "$PIN" <<'PY'
import hashlib, json, pathlib, plistlib, shutil, sys
source, dest, patch = map(pathlib.Path, sys.argv[1:4])
receipt = json.loads((source / 'FleetSDK.json').read_text())
assert receipt['revision'] == sys.argv[4]
assert receipt['privacyPatchSHA256'] == hashlib.sha256(patch.read_bytes()).hexdigest()
info = plistlib.loads((source / 'Info.plist').read_bytes())
libs = info['AvailableLibraries']
assert {(x['SupportedPlatform'], x.get('SupportedPlatformVariant')) for x in libs} == {('ios', None), ('ios', 'simulator')}
for lib in libs:
    assert 'arm64' in lib['SupportedArchitectures']
    binary = pathlib.Path(lib['LibraryIdentifier']) / lib['LibraryPath'] / 'TailscaleKit'
    assert (source / binary).is_file()
    assert receipt['binaries'][str(binary)] == hashlib.sha256((source / binary).read_bytes()).hexdigest()
    if dest.exists():
        assert (source / binary).read_bytes() == (dest / binary).read_bytes(), 'Existing SDK differs; remove only the reviewed Vendor artifact explicitly before replacing it.'
    print(str(binary), hashlib.sha256((source / binary).read_bytes()).hexdigest())
if not dest.exists():
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, dest)
print('Installed/verified device and simulator slices')
PY
