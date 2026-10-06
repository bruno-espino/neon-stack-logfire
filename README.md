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

Install the companion once with `tools/install-companion.sh`. It builds a native executable in `~/.local/bin`.
Add that directory to your PATH if needed. You can also use `swift run logfire-apple` from this checkout.

Configure a project write token once. The command hides input and saves a private runtime file outside the application and Git.
Existing prototype credentials remain compatible.

```sh
logfire-apple configure --region us
logfire-apple doctor
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
logfire-apple capture --last 10s
logfire-apple attach --seconds 30
```

Capture collects Apple's retained history and saves recordings and symbols locally.
Logfire receives selected summaries and capture metadata.
Attach streams selected native measurements and whole-host load during its bounded observation period.
Both commands use Swift only and report exporter acknowledgements and failures.
Add `--no-telemetry` to retain evidence locally without export.

## What supplies each measurement

| Source | Data | Logfire delivery |
| --- | --- | --- |
| Game + SDK frame recorder | Callback cadence, frame preparation time, Metal command duration, render context | Five-second windows during gameplay |
| SDK operation calls | Named operations and instrumented failures | Direct OTLP spans |
| Apple native tools | Presented FPS, frame-on-glass intervals, drawable waits, selected process resources | Companion attach or capture |
| MetricKit adapter inside the SDK | Selected CPU/GPU time, disk writes, launch/resume/hang distributions, hitches, daily Metal reports, diagnostic summaries | Delayed reports with historical context. Coverage varies by platform. |
| macOS host APIs | Whole-host CPU load, selected memory counts, filesystem free bytes | One-second samples during companion builds, game tests, and live attach |
| Xcode build tools | Build duration, task totals, warnings, errors, selected host samples | Swift companion build action |
| Native captures | Apple recordings and symbols | Files remain local. Selected measurements and metadata arrive in Logfire. |

Performance windows and Apple reports use span attributes. They are not OpenTelemetry metric instruments.
Callback FPS differs from presented FPS. GPU command duration does not measure GPU utilization.
Native resource CPU times are not CPU utilization percentages.

## Build and test with native tools

Ordinary Command-R embeds identity. Use the companion when you need complete build timing and retained result bundles.
All commands below use Swift and Apple tools. Python is not required.

```sh
logfire-apple build --scenario neon-release -- \
  -project examples/neon-stack/NeonStack.xcodeproj -scheme NeonStack \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath tmp/NeonStack build
logfire-apple test-game --app tmp/NeonStack/Build/Products/Release/NeonStack.app \
  --seconds 20 --seed 777 --render-mode aurora --aurora-layers 8
logfire-apple analyze --report PATH_TO_REPORT_JSON
```

The reference-game test runs fixed inputs and retains SDK windows.
Onscreen tests preserve Apple's state context from launch, then select presented-frame measurements with whole-second bounds around the completed SDK window interval.
The companion exports correlated summaries. The test app does not read credentials or duplicate the export.
Each test retains one report, its raw windows, console output, and available native evidence.

Compare two matching runs with `analyze --report NEW_REPORT --baseline BASELINE_REPORT`.
The command rejects incompatible cohorts and observation gaps.
It reports worst window p95 values. They are not whole-session percentiles.
See [the native workflow guide](docs/native-workflow.md) for setup, report fields, and exit codes.

The [legacy Python experiments](tools/xcode-observe/README.md) remain available for transport comparisons and earlier dashboards.
The companion does not call them.

## Validate and inspect

```sh
tools/check-dev.sh          # Swift tests and cached macOS Debug build
tools/check-dev.sh --smoke  # Also run a 12-second SDK-only session
```

Ordinary game edits use Command-R. iOS Simulator checks and performance-budget calibration are deferred during this macOS workflow iteration.
The unit tests remain available independently with `swift test`.
Manual sessions gain native and host telemetry when you run `logfire-apple attach`.
Automated sessions stream host samples while the app runs. Their SDK and capture summaries export after measurement.

[PROJECT.txt](docs/PROJECT.txt) contains the compact guide and terminology.
[WORKLOG.txt](docs/WORKLOG.txt) records decisions, verification, and next steps.
Captured files, local reports, credentials, and build caches stay outside Git.

The exporter has bounded batches and no persistent offline queue.
Lifecycle flushing is best effort. An abrupt debugger stop can lose the last batch.
Native companion capture currently requires a live verified session on macOS 27.
Real daily MetricKit delivery, physical iOS runtime, and a second tester Mac remain unverified.
