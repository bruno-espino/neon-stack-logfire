#!/bin/sh
set -eu
smoke=0
case ${1:-} in
    '') ;;
    --smoke) smoke=1 ;;
    --help)
        printf 'Usage: tools/check-dev.sh [--smoke]\n'
        printf 'Run Swift tests and an incremental macOS Debug build. --smoke adds a 12-second SDK-only game run.\n'
        exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then printf 'Use at most one option.\n' >&2; exit 2; fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
swift test --quiet
swift build --product logfire-apple --quiet
binary_dir=$(swift build --show-bin-path)
"$binary_dir/logfire-apple" build --scenario dev-check -- \
    -project "$root/examples/neon-stack/NeonStack.xcodeproj" -scheme NeonStack \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$root/tmp/DerivedData-macos" CODE_SIGNING_ALLOWED=NO build
if [ "$smoke" -eq 1 ]; then
    "$binary_dir/logfire-apple" test-game \
        --app "$root/tmp/DerivedData-macos/Build/Products/Debug/NeonStack.app" \
        --seconds 12 --no-native --output "$root/.xcode-observe/dev-smoke"
fi
printf 'Development check passed. Native performance comparisons and iOS Simulator checks are separate.\n'
