# Native reference games

Open `NeonStack.xcodeproj` with Xcode 27. Select **NeonStack**, **My Mac**, and press **Command-R**.
Choose Log Roll or Neon Stack in the app. Configure telemetry through [the SDK guide](../../docs/swift-sdk.md).
The native workflow needs no Python or relay.

## Play

Log Roll uses arrows or WASD. Q and E turn the camera. P pauses. R restarts.
Space restarts after a loss. The renderer includes fire particles and a glow pass.

Neon Stack uses arrows to move and rotate. Space drops. C holds or swaps once per piece. P pauses. R restarts.
Classic uses flat board colors. Neon adds glow. Aurora adds an adjustable layered GPU workload.
All modes share the same rules. Line clears have sound and animation. An empty board after a clear triggers the all-clear effect.

Set `NEON_FEEDBACK_SCENARIO=single`, `four`, or `all-clear` for a prepared Neon Stack board.
Select Neon Stack and press Space to exercise the effect. Exclude these demos from performance comparisons.

## Build and verify

Run `tools/check-dev.sh` from the repository root. It checks the SDK, companion, game logic, repository files, and a macOS Debug build.
Add `--smoke` for a 12-second offscreen Neon Stack replay. Simulator and profiler runs remain separate.

For an optimization baseline, build Release:

```sh
logfire-apple build --scenario release -- \
  -project examples/neon-stack/NeonStack.xcodeproj -scheme NeonStack \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath tmp/NeonStack build
```

Exercise Log Roll's app-owned assertions:

```sh
logfire-apple run --app tmp/NeonStack/Build/Products/Release/NeonStack.app \
  --scenario examples/neon-stack/scenarios/log-roll-two-mazes.json --seconds 20
```

Compare seeded Neon Stack workloads with `logfire-apple test-game --app APP --render-mode classic|neon|aurora`.
Use the same Release build, seed, drawable size, thermal conditions, and workload.
`--offscreen` renders a 600 by 1200 texture. Its callback cadence does not measure display presentation.
The adapter remains until scenario files cover its seeded comparison and offscreen features.

## Investigate

The SDK streams frame windows, process measurements, and optional main-queue probes.
The companion adds whole-host context during a build, run, replay, or attach command.
Read [the metric catalog](../../docs/telemetry-metrics.md) before interpreting these signals.
Callback FPS differs from presented FPS. Preparation time excludes other main-thread and SwiftUI work.
Window p95 values do not become a session p95 when averaged.

Use [the native workflow](../../docs/native-workflow.md) for CPU and GPU recordings, retained artifacts, and Logfire dashboard queries.
Native recordings remain local. Profiling adds overhead, so use unprofiled runs for baselines.
Configure each trusted tester machine separately. Builds do not embed credentials.
