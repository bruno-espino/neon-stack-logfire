#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/tools/xcode-env.sh"
cd "$root"
/usr/bin/xcrun swift build -c release --product logfire-apple
binary_dir=$(/usr/bin/xcrun swift build -c release --show-bin-path)
install_dir=${LOGFIRE_APPLE_INSTALL_DIR:-"$HOME/.local/bin"}
mkdir -p "$install_dir"
install -m 755 "$binary_dir/logfire-apple" "$install_dir/logfire-apple"
printf 'Installed %s/logfire-apple\n' "$install_dir"
printf 'Add this directory to PATH if necessary. No shell profile was changed.\n'
