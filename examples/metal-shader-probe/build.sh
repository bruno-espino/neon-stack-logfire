#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$root/tools/xcode-env.sh"
example="$root/examples/metal-shader-probe"
app="$root/tmp/MetalShaderProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/xcrun swiftc -swift-version 5 -O "$example/main.swift" -o "$app/Contents/MacOS/MetalShaderProbe"
cp "$example/Info.plist" "$app/Contents/Info.plist"
CONFIGURATION=Release SDK_NAME="macosx$(/usr/bin/xcrun --sdk macosx --show-sdk-version)" \
    XCODE_VERSION_ACTUAL="$xcode_major" /usr/bin/xcrun swift "$root/tools/embed-build.swift" \
    "$example" "$example" "$app/Contents/Resources/LogfireBuild.json"
printf 'Built %s\n' "$app"
