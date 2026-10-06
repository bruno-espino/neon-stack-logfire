# Logfire Swift prototype

This package uses the upstream OpenTelemetry Swift SDK and its experimental HTTP exporter.
It supports trusted developer and manual tester builds.

## Configure once

Run `swift run logfire-apple configure --region us` from the repository root.
Use `--region eu` for a European project. Supply a project write token, not a management API key.
The command hides input and saves `~/.config/logfire-swift/credentials.env` with permissions of `0600`.
The SDK also accepts the earlier `~/.config/xcode-observe/credentials.env` location.
The app reads credentials at runtime. The build never copies them into the application.

Set `LOGFIRE_DEV_DIRECT=1` in the development scheme.
Runtime `LOGFIRE_TOKEN` and `LOGFIRE_BASE_URL` variables can replace the file. Set both together.
Set `LOGFIRE_DEV_CREDENTIALS` for another private file. Keep credentials out of shared schemes.
Without opt-in, the SDK disables export and does not read the private file.
An enabled run with invalid credentials throws a sanitized configuration error.

## One retained client

```swift
import LogfireSwift

let telemetry = try Logfire.development(serviceName: "my-game", apple: .init(
    stateDomains: ["dev.example.my-game.rendering"],
    metadataKeys: ["quality"]))

let level = telemetry.withSpan("game.load", attributes: ["level": .int(1)]) {
    loadLevel(1)
}
```

The client starts optional MetricKit collection on OS 27 and requests lifecycle flushes.
It publishes a private macOS session marker for the companion.
It emits identity when the app includes `LogfireBuild.json`.
Set `apple: .init(metricKit: false)` to disable report collection.
Retain one client rather than starting multiple MetricKit managers for the same app.

The low-level `Logfire(serviceName:configuration:)` initializer remains available.
It does not start Apple report collection or publish a marker automatically.
Instrumented operations produce native signposts and Logfire spans over the same interval.
The package does not import arbitrary system signposts.

## Frame measurement and state

```swift
let frames = FrameRecorder(client: telemetry, stateDomain: "dev.example.my-game.rendering")
let context = RenderContext(mode: "high", width: 600, height: 1200,
    metadata: ["quality": .string("high")])

// Call after the command buffer completes.
frames.record(commandBuffer: commandBuffer,
    frameMilliseconds: callbackIntervalMilliseconds,
    preparationMilliseconds: framePreparationMilliseconds,
    context: context)
```

The renderer supplies callback intervals and elapsed preparation time.
The Metal adapter reads completed command-buffer timestamps.
The recorder excludes two seconds of warmup and exports five-second windows.
Context changes reset an incomplete window. Modes, sizes, and workloads do not share a window.
The recorder reports the same context through Apple StateReporting and Logfire.
Use a dedicated domain. The SDK owns its metadata types for that domain.
Do not register that domain through direct StateReporting calls with other types.

Use `telemetry.state(domain:label:metadata:)` for other application states.
`onWindow` receives values for a local report or display on the recorder's serial worker.
Call `frames.finish()` after the renderer stops submitting frames. Do not call it inside `onWindow`.

Callback FPS is not presented FPS. Preparation wall time is not CPU utilization.
GPU command duration is not hardware utilization or a full presentation timeline.
Absent GPU timestamps stay absent. Do not combine window percentiles into a session percentile.
The recorder retains at most 10,000 samples per window.

## MetricKit inside the SDK

The adapter consumes Apple's metric and diagnostic report sequences.
It exports selected CPU time, instruction counts, GPU time, disk writes, and hitch durations.
It retains launch, resume, and hang distributions as histogram buckets with seconds as the unit.
It exports daily Metal frame rates and selected rendering-state metadata.
Peak memory and memory-exception summaries use the iOS path.
Diagnostic summaries identify kinds, selected durations, signal numbers, and crash categories.
Raw exception text and diagnostic stacks are not exported by this prototype.

Reports retain historical measurement dates and the reported application build version.
They omit the current build ID and session ID. A report can cover multiple app versions.
Full-day and state records can overlap. Compare their scopes separately.
The report ID identifies repeated reports. The client does not deduplicate them.
The adapter exports the full-day interval and selected state entries.
It does not export every smaller interval from the report.

The existing `MetricKitReports` API remains available for manual report processing.
The unified client keeps its historical exporter separate from current-session resources.
Synthetic Apple reports verify decoding, units, timestamps, and context filtering.
Real Apple report delivery and physical iOS runtime remain unverified.

## Build and capture correlation

The example build phase runs `tools/embed-build.swift` with the macOS host SDK.
It embeds a build ID, source fingerprint, Git commit, configuration, SDK, and Xcode version.
It reads no credentials and performs no network request.
The app exports identity when it starts. Command-B alone creates local identity.
The Swift companion build action supplies full build timing and a build trace relationship.

```sh
swift run logfire-apple capture --last 10s
swift run logfire-apple attach --seconds 30
```

The companion selects a verified live SDK session and retains artifacts locally.
Logfire receives selected native display/resource summaries and capture metadata.
A recording can contain other processes. The exported overview selects our PID.
Neither `.atrc` nor Instruments `.trace` files become ordinary OpenTelemetry traces.
See [the compact guide](PROJECT.txt) for the workflow.

## Delivery and lifecycle

```swift
telemetry.flush() // Call from a background queue.
let status = telemetry.delivery
```

The status reports acknowledged and failed spans from attempted batches, including the client's MetricKit path.
It does not count queue-overflow or abrupt-process losses.
Acknowledgement does not independently verify that a record appears in a Logfire query.
Queues hold at most 256 spans. Batches hold at most 64 spans. HTTP requests have a three-second timeout.
Failed batches are dropped. Export failure does not replace the operation's result.
Lifecycle notifications request a flush outside the UI thread.
They do not guarantee delivery before suspension or termination. An abrupt debugger stop can lose the last batch.

The optional loopback relay remains available for transport comparisons.
Set `LOGFIRE_DEV_ENDPOINT=http://127.0.0.1:4318/v1/traces` without direct opt-in to use it.
The legacy relay experiment requires the optional Python environment. Native builds, game tests, and captures use Swift.
See [the native workflow](native-workflow.md) for automated testing and analysis.

Local Apple monitoring remains active when development network export is disabled.
The client retains each StateReporting reporter for its domain. Stable metadata selects performance cohorts.
Session and build IDs use volatile metadata. They do not fragment stable performance groups.
