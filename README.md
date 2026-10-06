# Neon Stack + Logfire

A native Metal falling-block game and an experimental Swift integration for Logfire.
The project connects app operations, performance measurements, builds, and native profiler captures.
It targets trusted developer and manual tester machines.
This is a private prototype. It is not an official released Logfire SDK.

## Start in Xcode

Use macOS with Xcode 27 and its Metal toolchain, Python 3.14, and `uv`.
Install the host tools before the first build. The Xcode build phase uses them to create build identity.

```sh
uv sync --frozen --project tools/xcode-observe
open examples/neon-stack/NeonStack.xcodeproj
```

Select **NeonStack**, **My Mac**, and press **Command-R**.
Configure a Logfire project write token in a private runtime file for direct app export.
Follow [the SDK setup](docs/swift-sdk.md). The shared scheme contains no credentials.
Without valid credentials, the game still runs and reports that telemetry is unavailable.
The scheme preserves LLDB debugging and starts no relay or native observer.

Use arrows to move and rotate, Space to drop, C to hold or swap, P to pause, and R to restart.
Classic, Neon, and Aurora share the same rules. Aurora adds an adjustable GPU workload.
The game includes sound, line-clear effects, and a special all-clear effect.
See [the game guide](examples/neon-stack/README.md) for touch controls and repeatable replays.

## What supplies each measurement

| Source | Data | Logfire delivery |
| --- | --- | --- |
| Game + Swift SDK | Operation spans, callback cadence, frame preparation time, Metal command duration, render context | Direct OTLP export while the game runs |
| Apple native tools | Presented FPS, frame-on-glass intervals, drawable waits | Explicit host attach or capture command exports selected summaries |
| Xcode build tools | Build duration, aggregate task times, warnings, errors, machine samples | Optional build wrapper |
| Native captures | Detailed Apple recordings and symbols | Files remain local. Logfire receives capture metadata and selected summaries. |
| MetricKit bridge | Delayed daily Metal reports | Experimental historical spans. Real daily delivery is unverified. |

Runtime performance windows use span attributes. They are not OpenTelemetry metric instruments.
Callback FPS differs from presented FPS. GPU command duration does not measure GPU utilization.
Ordinary Xcode builds export build identity. Full build timing requires the build wrapper.

## Layout

- `Package.swift`, `Sources/`, and `Tests/` contain the Swift package. Add this repository directly in Xcode as a package dependency.
- `examples/neon-stack/` contains the macOS and iOS Simulator game.
- `tools/xcode-observe/` contains optional build, replay, relay, and native capture commands.
- [PROJECT.txt](docs/PROJECT.txt) contains the compact project guide and terminology.
- [WORKLOG.txt](docs/WORKLOG.txt) records decisions, limits, and next steps.

## Validate

Run from the repository root.

```sh
swift test
uv run --frozen --project tools/xcode-observe pytest \
  -c tools/xcode-observe/pyproject.toml tools/xcode-observe/tests
uv run --frozen --project tools/xcode-observe ruff check tools/xcode-observe examples/neon-stack/run.py
xcodebuild -project examples/neon-stack/NeonStack.xcodeproj -scheme NeonStack \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath tmp/DerivedData-macos CODE_SIGNING_ALLOWED=NO build
```

The host tools retain build and profiler artifacts locally. Keep those artifacts and credential files outside Git.
The direct exporter uses bounded batches and drops failed batches. It has no persistent offline queue.
Physical iOS runtime, real MetricKit delivery, and a second tester Mac remain verification tasks.
