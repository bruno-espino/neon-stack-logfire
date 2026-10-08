# Logfire Swift prototype

This package uses the upstream OpenTelemetry Swift SDK and its experimental HTTP exporter.
It supports trusted developer and manual tester builds.

## Add the SDK to an app

In Xcode, add `https://github.com/bruno-espino/neon-stack-logfire.git` as a package dependency.
Select the `main` branch for the current development pilot.
Link only the `LogfireSwift` library product to the application target.
This branch can change. The project has no version tags yet.
Use a reviewed revision for a reproducible pilot. Use a semantic version after the first release.
The game and companion executable do not become application dependencies.

Swift package consumers can add this dependency and target product:

```swift
.package(url: "https://github.com/bruno-espino/neon-stack-logfire.git",
         branch: "main")

.product(name: "LogfireSwift", package: "neon-stack-logfire")
```

The companion is optional for SDK telemetry.
Supply `LOGFIRE_DEV_DIRECT=1`, `LOGFIRE_TOKEN`, and `LOGFIRE_BASE_URL` through a private runtime environment.
Use `https://logfire-us.pydantic.dev` or `https://logfire-eu.pydantic.dev` for the base URL.
The SDK appends `/v1/traces`. Do not put the token in source code or a shared scheme.
Alternatively, use the companion's hidden-input configuration command below.

Operation spans work without build integration.
Build correlation requires an application resource named `LogfireBuild.json`.
The example build phase calls `tools/embed-build.swift` with explicit app-source and package roots.
Adapt that phase to your target. The companion does not install it automatically.
Capture and attach can use another instrumented macOS app's verified session marker.
The automated `test-game` action controls only the NeonStack reference game.

The SDK target compiles in Swift 6 mode. The companion remains in Swift 5 mode.
Clients, recorders, configuration, and frame context support Sendable use.
Locks protect recorder state and registries. Audited bridges cover upstream OTel types without Sendable annotations.
The package supports synchronous and async `withSpan` operations. It does not automatically instrument URLSession.

```swift
try await telemetry.withSpan("game.load") {
    try await loadLevel()
}
```

SDK async operations use Swift TaskLocal context. Structured child tasks inherit that context.
Detached tasks require explicit context propagation. The SDK does not replace OTel's global context manager.
Third-party async OTel instrumentation needs its own compatible context setup.
Synchronous SDK operations still activate the upstream OTel context.
Retain one client. Do not create a client for each frame or operation.

## Configure once

The [repository setup](../README.md#configure-this-mac) supplies the shortest reference-game path.
Use the independent [Swift 6 consumer](../examples/sdk-consumer/README.md) to verify a package-only app.

Install the companion with [the native setup guide](native-workflow.md#install-once).
Run `logfire-apple configure --region us`.
You can also use `swift run logfire-apple` from this checkout.
Use `--region eu` for a European project. Supply a project write token, not a management API key.
The command hides input and saves `~/.config/logfire-swift/credentials.env` with permissions of `0600`.
The SDK reads only this location by default. Prototype users must run `logfire-apple configure` again.
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
Context changes publish the previous partial window. Modes, sizes, and workloads do not share a window.
The recorder reports the same context through Apple StateReporting and Logfire.
Use a dedicated domain. The SDK owns its metadata types for that domain.
Do not register that domain through direct StateReporting calls with other types.

Use `telemetry.state(domain:label:metadata:)` for other application states.
`onWindow` receives values for a local report or display on the recorder's serial worker.
Register drawable observation before the renderer presents it:

```swift
frames.observe(drawable, context: context)
commandBuffer.present(drawable)
```

Continue recording completed command buffers. Presentation observation complements renderer timing.
`display_presented_fps` and `display_present_interval_p95_ms` use valid Metal presentation timestamps.
Zero timestamps do not become timing samples. Unknown presentations do not become a dropped-frame count.
Provide `targetPresentationTime` only when the render loop supplies a target in Metal's host clock.
The recorder then reports nonnegative presentation lateness. This does not establish a missed-refresh count.
The SDK integrates with MTKView or an engine's current loop. It does not replace it with CAMetalDisplayLink.

`client.flush()` publishes and drains pending recorder windows before exporter collection.
Call it outside `onWindow` to drain the serial writer. Calls inside that callback cannot drain later queued work.
Call `frames.finish()` after rendering and its completion/presentation callbacks stop. It closes the recorder and ignores later callbacks.
Final and context-change windows use `window.partial=true`. The companion excludes them from regression comparisons.
A presentation-only tail has `frames=0` and omits callback statistics. `FrameWindow.callbackFPS` remains zero for source compatibility.

Callback FPS is not presented FPS. Preparation wall time is not CPU utilization.
Renderer windows exclude other main-thread and SwiftUI work. They publish `main_thread.measured=false` and the preparation measurement scope.
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
logfire-apple capture --last 10s
logfire-apple attach --seconds 30
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

Development export uses HTTPS directly. No relay or Python environment is required.
See [the native workflow](native-workflow.md) for automated testing and analysis.

Local Apple monitoring remains active when development network export is disabled.
The client retains each StateReporting reporter for its domain. Stable metadata selects performance cohorts.
Session and build IDs use volatile metadata. They do not fragment stable performance groups.


## Optional development scenarios

A runner-owned launch sets `LOGFIRE_SESSION_ID`, `LOGFIRE_SESSION_DIR`, `LOGFIRE_SCENARIO_ID`, and `LOGFIRE_SCENARIO_STATUS`.
The SDK accepts the common `LOGFIRE_*` session names. Game-specific settings remain in the reference app.
Use one `Logfire.development` client so the app publishes its verified session marker.

```swift
let scenario = DevelopmentScenario(client: telemetry)
// In a renderer's onWindow callback:
try scenario?.record(window)
// A non-rendering app can declare its own startup condition:
try scenario?.markReady()
```

`DevelopmentScenario` is nil during an ordinary launch. It does not add a daemon or change Command-R.
The app owns its scenario actions and assertions.
Call `try scenario?.finish(passed: assertionsPassed, details: details)` on a background queue.
The method flushes queued telemetry before it publishes a terminal assertion.
Handle file-write failures. The runner treats absent assertions as failures.
Keep details compact. The status limit is 64 KiB.
All SDK spans include the supplied scenario ID during a runner launch.
The [native runner guide](native-workflow.md#run-an-app-owned-scenario) shows the command and JSON definition.

## Native development metrics and responsiveness

A configured client exports traces and metrics through the same runtime credentials.
The metrics endpoint is `/v1/metrics`. The reader exports every five seconds.
`client.metrics?.delivery` reports acknowledged and failed instrument exports.
These counts describe attempted exports, not unique observations or durable delivery.

`FrameRecorder` records individual frame intervals, preparation durations, and GPU command durations into delta histograms.
It records these values after full and partial windows, outside the renderer callback.
Warmup remains excluded. Graceful flushes retain final samples and do not replay delta observations.
Histograms have finer bounds around 60 Hz and 120 Hz frame budgets.
Histogram quantiles remain estimates. Window reports retain their exact sampled percentiles.

Use `RenderContext(..., gpuTimeScope: .commandBufferSum)` for a sum of multiple command buffers.
A command-buffer sum is not display latency or hardware utilization.
Metric labels retain the GPU timing scope.

Enable `AppleMonitoring(responsiveness: true)` to observe the main queue independently.
The monitor posts at most one probe every 100 milliseconds.
A stalled queue cannot accumulate more than one outstanding probe.
Completed probe delays enter `app.main_queue.delay`.
`app.main_queue.pending_age.max` records the oldest pending probe age within each five-second window.
The monitor also samples main-thread CPU time and macOS process CPU time and footprint.
CPU ratios use one core and wall time. Process CPU can exceed 1.
Queue delay includes OS scheduling and does not identify the function or resource responsible.
The first window can include startup. Physical iOS behavior remains unverified.

`event` emits a Logfire log record. `window` emits a measurement log at its end time.
Window records retain `measurement.started_at` and `measurement.ended_at`.
`withSpan` remains a timed operation with matching native signposts.
Automated app runs inherit the launcher's W3C parent context across threads.
The runner keeps its completion summary inside the run span.
An ordinary Command-R launch has separate operation traces and correlated session records.

See `examples/responsiveness-probe` for a controlled sleep-versus-busy-work experiment.

## Delivery and native correlation

Trace and metric exporters send gzip-compressed OTLP protobuf over HTTPS.
iOS lifecycle flushes request a finite UIApplication background task before queueing the upload.
Completion and expiration end the task once. Consecutive lifecycle notifications coalesce while an upload runs.
This improves the opportunity to finish. Suspension, abrupt stops, and network failures can still leave gaps.
Physical-device lifecycle behavior remains unverified. The generic iOS SDK build covers compilation only.

The desktop credential file does not provision physical iOS devices.
An app can supply `LogfireConfiguration(endpoint:token:)` from its own trusted tester provisioning flow.
Keychain storage needs initial provisioning. An Info.plist token remains visible in the app bundle.

Operation signposts include session, trace, and span IDs in Points of Interest.
SDK event, window, and flush markers use the Telemetry category.
Window markers include measurement dates. They are report markers, not backdated native intervals.

The [presentation probe](../examples/presentation-probe/README.md) verifies actual onscreen callbacks and complete histogram counts.
