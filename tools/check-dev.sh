#!/bin/sh
set -eu
smoke=0
case ${1:-} in
    '') ;;
    --smoke) smoke=1 ;;
    --help)
        printf 'Usage: tools/check-dev.sh [--smoke]\n'
        printf 'Check repository files, game logic, Swift tests, and an incremental macOS Debug build. --smoke adds a 12-second offscreen SDK-only game run.\n'
        exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then printf 'Use at most one option.\n' >&2; exit 2; fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/tools/xcode-env.sh"
cd "$root"
/usr/bin/xcrun swift-format lint --strict --configuration .swift-format tools/embed-build.swift tools/check-repository.swift tools/check-presentation.swift tools/check-preview.swift
/usr/bin/xcrun swift tools/check-repository.swift
tools/check-game.sh
/usr/bin/xcrun swift test --quiet
/usr/bin/xcrun swift build --product logfire-apple --quiet
binary_dir=$(/usr/bin/xcrun swift build --show-bin-path)
"$binary_dir/logfire-apple" build --scenario dev-check -- \
    -project "$root/examples/neon-stack/NeonStack.xcodeproj" -scheme NeonStack \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$root/tmp/DerivedData-macos" CODE_SIGNING_ALLOWED=NO build
if [ "$smoke" -eq 1 ]; then
    "$binary_dir/logfire-apple" test-game \
        --app "$root/tmp/DerivedData-macos/Build/Products/Debug/NeonStack.app" \
        --seconds 12 --offscreen --no-native --output "$root/.xcode-observe/dev-smoke"
fi
printf 'Development check passed. Native performance comparisons and iOS Simulator checks are separate.\n'
