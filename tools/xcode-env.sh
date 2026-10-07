#!/bin/sh
# Source this file before local Swift checks or companion installation.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR=$(/usr/bin/xcode-select -p)
    if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
export DEVELOPER_DIR
if ! xcode_version=$(/usr/bin/xcrun xcodebuild -version 2>/dev/null); then
    printf 'Select full Xcode 27 or newer. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
    exit 2
fi
xcode_major=$(printf '%s\n' "$xcode_version" | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p')
if [ -z "$xcode_major" ] || [ "$xcode_major" -lt 27 ]; then
    printf 'These native checks require Xcode 27 or newer. Selected: %s\n' "$DEVELOPER_DIR" >&2
    exit 2
fi
printf 'Using %s (%s)\n' "$DEVELOPER_DIR" "$(printf '%s\n' "$xcode_version" | head -n 1)"
