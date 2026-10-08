#!/bin/sh
set -eu
case ${1:-} in
    '') local_flag='' ;;
    --no-telemetry) local_flag='--no-telemetry' ;;
    --help) printf 'Usage: tools/check-presentation.sh [--no-telemetry]\nBuild a small Metal app and verify normal versus half-rate presentation through two 12-second scenarios.\n'; exit 0 ;;
    *) printf 'Use --no-telemetry or no argument.\n' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then printf 'Use at most one option.\n' >&2; exit 2; fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/tools/xcode-env.sh"
cd "$root"
umask 077
output="$root/.xcode-observe/presentation-verification/$(uuidgen)"
app="$output/PresentationProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/xcrun swift build --product LogfireSwift -j 2
/usr/bin/xcrun swift build --product logfire-apple -j 2
products=$(/usr/bin/xcrun swift build --show-bin-path)
/usr/bin/xcrun swiftc -I "$products" examples/presentation-probe/main.swift \
    "$products/libLogfireSwift.a" -o "$app/Contents/MacOS/PresentationProbe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.logfire.presentation-probe</string>
<key>CFBundleName</key><string>PresentationProbe</string>
<key>CFBundleExecutable</key><string>PresentationProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
CONFIGURATION=Debug SDK_NAME="macosx$(/usr/bin/xcrun --sdk macosx --show-sdk-version)" \
    XCODE_VERSION_ACTUAL="$(/usr/bin/xcrun xcodebuild -version | head -n 1)" /usr/bin/xcrun swift tools/embed-build.swift \
    "$root/examples/presentation-probe" "$root" "$app/Contents/Resources/LogfireBuild.json"
for mode in normal half-rate; do
    if ! "$products/logfire-apple" run --app "$app" \
        --scenario "$root/examples/presentation-probe/scenarios/$mode.json" \
        --output "$output/$mode" $local_flag; then
        printf 'The %s scenario is incomplete. Retaining evidence and continuing the other policy.\n' "$mode" >&2
    fi
done
/usr/bin/xcrun swift tools/check-presentation.swift "$output/normal" "$output/half-rate"
printf 'Retained verification: %s\n' "$output"
