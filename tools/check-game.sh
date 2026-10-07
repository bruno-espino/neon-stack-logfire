#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/tools/xcode-env.sh"
cd "$root"
output="$root/tmp/game-tests"
mkdir -p "$output"
source="$root/examples/neon-stack/NeonStack"
/usr/bin/xcrun swiftc -Onone "$source/GameEngine.swift" examples/neon-stack/tests/EngineTests.swift -o "$output/engine"
"$output/engine"
/usr/bin/xcrun swiftc -Onone "$source/GameEngine.swift" "$source/LogRollEngine.swift" "$source/LogRollScenario.swift" "$source/LogRollHUDSchedule.swift" examples/neon-stack/tests/LogRollTests.swift -o "$output/log-roll"
"$output/log-roll"
/usr/bin/xcrun swiftc -Onone "$source/GameFeedback.swift" examples/neon-stack/tests/FeedbackTests.swift -o "$output/feedback"
"$output/feedback" --no-playback
