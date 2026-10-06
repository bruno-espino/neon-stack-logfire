# Neon Stack + Logfire

A native Metal falling-block game and an experimental Swift integration for Logfire.
The project connects app operations, performance measurements, builds, and Apple profiler captures.
It targets trusted developer and manual tester machines. It is not an official released Logfire SDK.

## Run the game

Use macOS with Xcode 27 and its Metal toolchain.

```sh
open examples/neon-stack/NeonStack.xcodeproj
```

Select **NeonStack**, **My Mac**, and press **Command-R**.
Ordinary runs require no Python, relay, or native observer.
A host Swift script embeds build identity. The SDK exports identity when the app starts.
The game still runs if telemetry configuration is unavailable.

Configure a project write token once. The command hides input and saves a private runtime file outside the application and Git.
Existing prototype credentials remain compatible.

```sh
swift run logfire-apple configure --region us
swift run logfire-apple doctor
```

Use arrows to move and rotate, Space to drop, C to hold or swap, P to pause, and R to restart.
Classic, Neon, and Aurora share the rules. Aurora adds an adjustable GPU workload.
The game includes sound, line-clear effects, and a special all-clear effect.
See [the game guide](examples/neon-stack/README.md) for controls and repeatable replays.

## Use the package in another app

Add this repository as a Swift package dependency. Link the `LogfireSwift` product.
Enable `LOGFIRE_DEV_DIRECT=1` in the development scheme. Retain one client for the app.

```swift
import LogfireSwift

let telemetry = try Logfire.development(serviceName: "my-app")
telemetry.withSpan("app.load") {
    loadApplicationData()
}
```

The client manages operation spans, native operation signposts, lifecycle flush requests, and optional MetricKit reports.
See [the SDK guide](docs/swift-sdk.md) for frame recording and shared rendering context.
Apple controls MetricKit report delivery. Its metric reports do not provide live frame telemetry.

## Capture native evidence

Keep the app running. The companion finds the latest verified SDK session.
Use `--service NAME` if multiple applications run.

```sh
swift run logfire-apple capture --last 10s
swift run logfire-apple attach --seconds 30
```

Capture collects Apple's retained history and saves recordings and symbols locally.
Logfire receives selected summaries and capture metadata.
Attach streams selected native measurements during its bounded observation period.
Both commands use Swift only and report exporter acknowledgements and failures.
Add `--no-telemetry` to retain evidence locally without export.

## What supplies each measurement

| Source | Data | Logfire delivery |
| --- | --- | --- |
| Game + SDK frame recorder | Callback cadence, frame preparation time, Metal command duration, render context | Five-second windows during gameplay |
| SDK operation calls | Named operations and instrumented failures | Direct OTLP spans |
| Apple native tools | Presented FPS, frame-on-glass intervals, drawable waits, selected process resources | Companion attach or capture |
| MetricKit adapter inside the SDK | Selected CPU/GPU time, disk writes, launch/resume/hang distributions, hitches, daily Metal reports, diagnostic summaries | Delayed reports with historical context. Coverage varies by platform. |
| Xcode build tools | Full build duration, task totals, warnings, errors, machine samples | Optional build observer |
| Native captures | Apple recordings and symbols | Files remain local. Selected measurements and metadata arrive in Logfire. |

Performance windows and Apple reports use span attributes. They are not OpenTelemetry metric instruments.
Callback FPS differs from presented FPS. GPU command duration does not measure GPU utilization.
Native resource CPU times are not CPU utilization percentages.

## Optional full build observation

Install Python host tools only for full build timing, host metrics, or controlled replay workflows.
They remain available through the companion's build action.

```sh
uv sync --frozen --project tools/xcode-observe
swift run logfire-apple build --scenario neon-release -- \
  -project examples/neon-stack/NeonStack.xcodeproj -scheme NeonStack \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
```

The app receives the observed build ID and trace relationship through its identity resource.
Ordinary Command-R supplies identity without full build timing.
See [the host tools](tools/xcode-observe/README.md) for artifacts, dashboards, and limits.

## Validate and inspect

```sh
swift test
uv run --frozen --project tools/xcode-observe pytest \
  -c tools/xcode-observe/pyproject.toml tools/xcode-observe/tests
```

[PROJECT.txt](docs/PROJECT.txt) contains the compact guide and terminology.
[WORKLOG.txt](docs/WORKLOG.txt) records decisions, verification, and next steps.
Captured files, local reports, credentials, and build caches stay outside Git.

The exporter has bounded batches and no persistent offline queue.
Lifecycle flushing is best effort. An abrupt debugger stop can lose the last batch.
Native companion capture currently requires a live verified session on macOS 27.
Real daily MetricKit delivery, physical iOS runtime, and a second tester Mac remain unverified.
