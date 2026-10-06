#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
output="$root/tmp/game-tests"
mkdir -p "$output"
source="$root/examples/neon-stack/NeonStack"
xcrun swiftc -Onone "$source/GameEngine.swift" examples/neon-stack/tests/EngineTests.swift -o "$output/engine"
"$output/engine"
xcrun swiftc -Onone "$source/GameEngine.swift" "$source/LogRollEngine.swift" "$source/LogRollScenario.swift" examples/neon-stack/tests/LogRollTests.swift -o "$output/log-roll"
"$output/log-roll"
xcrun swiftc -Onone "$source/GameFeedback.swift" examples/neon-stack/tests/FeedbackTests.swift -o "$output/feedback"
"$output/feedback" --no-playback
