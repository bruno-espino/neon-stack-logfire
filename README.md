# Neon Stack + Logfire

Two native Metal games and an experimental Swift integration for Logfire.
Log Roll exercises compute particles, scene rendering, and glow. Neon Stack provides the original falling-block workload.
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
logfire-apple doctor --send
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

The client manages operation spans, native signposts, OTel metrics, lifecycle flush requests, and optional Apple monitoring.
See [the SDK guide](docs/swift-sdk.md) for frame recording and shared rendering context.
Apple controls MetricKit report delivery. Its metric reports do not provide live frame telemetry.
The SDK guide includes package installation without the companion.
The [distribution plan](docs/native-workflow.md#package-and-distribution) separates reusable integration from the reference game.

## Visualize the native workflow

Import [Apple Development Workflow](dashboards/apple-development.json) into a Logfire custom dashboard.
It includes twenty-two panels for SDK windows, Apple presentation timings, process memory, host context, CPU caller paths, GPU replay costs, diagnoses, captures, and builds.
Leave Session and Build empty to show all records. Paste exact IDs to filter.
Copy a session's build ID into Build to connect runtime evidence to an observed build.
The Session filter does not apply to the build table. Builds and app runs have different session IDs.

The dashboard combines native OTel metrics with diagnostic records. Direct Swift export uses no Python collector.
Capture aggregates remain separate from live measurements. Full recordings remain local.
See [dashboard setup and query limits](docs/native-workflow.md#logfire-dashboard).
The [metric catalog and verified experiments](docs/telemetry-metrics.md) explain what each signal measures.

## Capture native evidence

Keep the app running. The companion finds the latest verified SDK session.
Use `--service NAME` if multiple applications run.

```sh
logfire-apple capture --last 10s
logfire-apple attach --seconds 30
logfire-apple profile --seconds 5
```

Capture collects Apple's retained history and saves recordings and symbols locally.
Logfire receives selected summaries and capture metadata.
Attach streams selected native measurements and whole-host load during its bounded observation period.
Profile records a short Time Profiler interval and exports selected CPU samples and the top 20 leaf functions.
It also exports up to 20 caller paths for each main/background thread scope. Unresolved frames remain explicit.
For automated scenarios, `run --profile cpu` records during the app run, then exports and decodes the recording after the runner stops the app.
Use a Release build for optimization. The full `.trace` and symbols remain local.
All three commands use Swift only and report exporter acknowledgements and failures.
Add `--no-telemetry` to retain evidence locally without export.
For targeted GPU inspection, launch with `MTL_CAPTURE_ENABLED=1` and use `logfire-apple gpu-capture --profile`.
This captures one boundary by default and profiles its replay. It is separate from ordinary frame-latency measurements.

## What supplies each measurement

| Source | Data | Logfire delivery |
| --- | --- | --- |
| Game + SDK frame recorder | Callback cadence, frame preparation time, Metal command duration, render context | Five-second windows during gameplay |
| SDK responsiveness monitor | Main-queue delay, pending probe age, main-thread/process CPU ratios, macOS process footprint | Opt-in independent probes and five-second reports |
| SDK operation calls | Named operations and instrumented failures | Direct OTLP spans |
| Apple native tools | Presented FPS, frame-on-glass intervals, drawable waits, selected process resources | Companion attach or capture |
| Apple GPU debugger | Captured render/compute workload, selected replay encoder/shader costs, register and spill properties | Optional `gpu-capture --profile`. Raw resources and shader sources stay local. |
| Instruments Time Profiler | Running CPU samples, leaf-function weights, and caller paths | Optional `profile` recording. Summaries export after the recording. |
| MetricKit adapter inside the SDK | Selected CPU/GPU time, disk writes, launch/resume/hang distributions, hitches, daily Metal reports, diagnostic summaries | Delayed reports with historical context. Coverage varies by platform. |
| macOS host APIs | Whole-host CPU load, selected memory counts, filesystem free bytes | One-second samples during companion builds, game tests, and live attach |
| Xcode build tools | Build duration, task totals, warnings, errors, selected host samples | Swift companion build action |
| Native captures | Apple recordings and symbols | Files remain local. Selected measurements and metadata arrive in Logfire. |

The SDK exports raw frame histograms and development gauges/counters to `/v1/metrics`. Diagnostic reports retain detailed attributes in `records`.
Callback FPS differs from presented FPS. GPU command duration does not measure GPU utilization.
Native resource CPU times are not CPU utilization percentages.
Frame preparation timings exclude other main-thread and SwiftUI work. `main_thread.measured=false` makes that gap explicit.
GPU replay timing and shader wait-instruction counts are separate from live frame latency and CPU blocking.

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

Run Log Roll's short two-maze regression scenario with the reusable app runner:

```sh
logfire-apple run --app tmp/DerivedData-macos/Build/Products/Debug/NeonStack.app \
  --scenario examples/neon-stack/scenarios/log-roll-two-mazes.json
```

The app supplies readiness and completion through the SDK. The runner stops after the expected loss and retains one report.
Add `--profile cpu` or `--profile gpu` for a targeted investigation. Profiling adds time and is absent from default checks.
The run report includes diagnostic findings, missing evidence, caller paths, and suggested native investigations.
Use `logfire-apple diagnose --report REPORT` to reanalyze saved evidence without another gameplay run or telemetry upload.
See [the scenario workflow](docs/native-workflow.md#run-an-app-owned-scenario) for the reusable definition and SDK protocol.

Manual sessions gain native and host telemetry when you run `logfire-apple attach`.
Automated sessions stream host samples while the app runs. Their SDK and capture summaries export after measurement.

[PROJECT.txt](docs/PROJECT.txt) contains the compact guide and terminology.
[WORKLOG.txt](docs/WORKLOG.txt) records decisions, verification, and next steps.
Captured files, local reports, credentials, and build caches stay outside Git.

The exporter has bounded batches and no persistent offline queue.
Lifecycle flushing is best effort. An abrupt debugger stop can lose the last batch.
Native companion capture currently requires a live verified session on macOS 27.
Real daily MetricKit delivery, physical iOS runtime, and a second tester Mac remain unverified.
