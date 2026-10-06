# Logfire Swift prototype

This experimental package connects native Apple development to Logfire through
the OpenTelemetry Swift SDK. It uses the upstream OTLP HTTP exporter.
The package does not implement a separate telemetry protocol.

## Run the working example

Install Xcode 27 and the standalone observer dependencies.
Run this command from the repository root.

```sh
uv sync --project tools/xcode-observe
"$(xcode-select -p)/../MacOS/Xcode" examples/neon-stack/NeonStack.xcodeproj &
```

Select the NeonStack scheme and the My Mac destination. Press Command-R.
The command opens the selected Xcode application directly.
This scheme retains LLDB debugging and enables direct HTTPS export with `LOGFIRE_DEV_DIRECT=1`.
It starts no relay or live Metal observer. Capture Apple's retained history on demand.
Use the host attach command when you need continuous Apple Metal summaries.
The game exports operation spans and performance windows during the session.
The first complete window follows two seconds of warmup and five seconds of measurements.
The export worker batches spans approximately every second.

The app reads `~/.config/xcode-observe/credentials.env` at runtime on the Mac.
This private file must contain `LOGFIRE_TOKEN` and `LOGFIRE_BASE_URL`.
Use a project write token and the HTTPS endpoint for its region.
Keep the directory private and give the file permissions of `0600`.
The file stores the token on each trusted development or tester machine.
The build does not copy the token or credential file into the application.
`LOGFIRE_TOKEN` and `LOGFIRE_BASE_URL` runtime variables can replace the file.
Set both variables together. Do not put their values in a shared Xcode scheme.
Set `LOGFIRE_DEV_CREDENTIALS` to use a different private file.

## Optional relay

The relay remains available for transport comparisons. No Xcode scheme starts it.
Disable direct opt-in and set the explicit loopback endpoint to use that transport.

Inspect or stop the relay from the repository root.

```sh
tools/xcode-observe/.venv/bin/xcode-dev-relay status
tools/xcode-observe/.venv/bin/xcode-dev-relay stop
```

The relay listens only on the Mac loopback interface.
It exits after one hour without an export request.
The relay log stays in the private configuration directory.
Its health response contains request counters and its process ID.
The relay forwards OTLP bytes and adds the write token on the host.
It has no disk buffer or retry queue.
This relay is a local development tool. It is not a production ingest service.

## Use the package

Add this repository root as a local Swift package dependency.
Alternatively, add its private GitHub URL in Xcode with a GitHub account that has access.
Link its `LogfireSwift` product to the application target.

```swift
import LogfireSwift

let telemetry = Logfire(serviceName: "my-game", configuration: try .development())
let level = telemetry.withSpan("game.load_level", attributes: ["level": .int(1)]) {
    loadLevel(1)
}
```

Set `LOGFIRE_DEV_DIRECT=1` in the development scheme and configure runtime credentials.
The package throws a sanitized configuration error if an enabled direct run lacks valid credentials.
Without direct opt-in or an explicit relay endpoint, the package disables network telemetry.
It does not read the private file in that disabled mode.
For the relay, set `LOGFIRE_DEV_ENDPOINT=http://127.0.0.1:4318/v1/traces` instead.
The relay endpoint helper accepts only an explicit loopback URL.
The Swift package itself needs no Python process or host CLI for direct export.
The package uses a private tracer provider and preserves nested span context.
An operation failure marks its span as an error without exporting the error text.
The same operation creates an Instruments signpost under `dev.logfire.swift`.
Existing game signposts remain available under `dev.example.NeonStack`.
The integration creates signposts from instrumented operations.
It does not import arbitrary system signposts.

The background batch queue holds at most 256 waiting spans.
Exports use batches of at most 64 spans and a three-second network timeout.
Failed batches are dropped. The game continues when Logfire or the relay is unavailable.
Call `flush()` from a background queue before suspending the application.
An abrupt stop can lose the last batch.

## Measurement contract

| Data | Measurement producer | Delivery to Logfire |
| --- | --- | --- |
| Gameplay operations and instrumented failures | Game calls the Swift SDK | Runtime operation spans |
| Callback cadence and frame preparation wall time | Game renderer instrumentation | Five-second span attributes through the SDK |
| GPU command duration | Game reads completed Metal command-buffer timestamps | Five-second span attributes through the SDK |
| Render mode, drawable size, detail, and thermal state | Game and Apple runtime APIs | Context on the SDK windows |
| Presented FPS, skipped frames, and drawable waits | Apple metalperftrace | Host attach or capture command exports selected summaries |
| Daily Metal frame-rate reports | Apple MetricKit through the Swift bridge | Delayed spans. Synthetic export passes. Real delivery is pending. |
| Build duration, task totals, warnings, and errors | xcodebuild and the host build wrapper | Build traces and selected metric instruments |
| Machine CPU, memory, and free disk during builds | Host sampler | Host metrics and build sample records |
| Native signposts and profiler recordings | Game/SDK and Apple profiling tools | Recordings remain local. Capture metadata and selected summaries arrive in Logfire. |

The SDK transports the game measurements. It does not pull all measurements from Xcode.
Xcode debugger gauges and detailed native profiler views do not automatically export through the SDK.
Ordinary Cmd-R exports build identity. The build wrapper supplies full build timing.

The game exports `game.session.started`, `game.drop`, `game.hold`,
`game.rotate`, `game.line_clear`, and `game.performance.window`.
Operation spans use their actual start and end times.
Each performance span covers its five-second measurement interval.
Every span carries a random session ID.
Nested operations share a trace. Independent windows use the session ID for correlation.
Performance windows are span attributes, not OpenTelemetry metric instruments.

GPU command duration comes from completed Metal command buffers.
Frame intervals come from renderer callbacks.
`frame_encode_wall_p95_ms` measures elapsed frame preparation time.
The legacy `cpu_frame_p95_ms` attribute carries the same value.
Neither attribute measures CPU utilization.
Windows restart when the render mode, drawable size, workload, or Aurora detail changes.
This avoids mixing different rendering conditions in one window.

The app reads build context from its embedded `LogfireBuild.json` resource.
Every operation and window carries that build ID and build trace relationship.
The build phase passes wrapped build identity through to the app.
Ordinary Xcode builds export an identity record from the host.
The app publishes a development session marker with its PID and executable path.
The macOS 27 observer verifies that marker before collecting Apple measurements.
Native signposts include the session ID for capture correlation.
See [the compact project guide](PROJECT.txt) for capture commands.
The build observer still emits build telemetry separately.
The replay wrapper strips native export configuration from its child process.
Thus, a replay does not export the same windows through both paths.
Instruments captures still require an explicit profiling run.
No `.trace` file is uploaded or decoded by this package.

## Verify and inspect

```sh
swift test
uv run --project tools/xcode-observe pytest tools/xcode-observe/tests
```

Query the project for native spans.

```sql
SELECT start_timestamp, end_timestamp, span_name, attributes, trace_id
FROM records
WHERE service_name = 'neon-stack' AND kind = 'span'
ORDER BY start_timestamp DESC
LIMIT 100
```

The `neon-stack-performance` dashboard contains native operations and windows.
Its replay comparison panel retains the controlled replay cohorts.
Use live windows for diagnosis. Use matched replays for optimization comparisons.

## Prototype limits and adoption

The upstream Swift tracing SDK is stable. Its HTTP exporter is experimental.
This package is an experimental development integration, not a released Logfire SDK.
It does not provide automatic Metal capture, MetricKit diagnostic stacks, production
mobile credential management, persistent offline delivery, or shared capture artifact hosting.
The macOS example provides the runtime verification path.
An iOS Simulator build is a compilation check, not device runtime verification.

The product question is whether ordinary Xcode runs can produce useful native telemetry.
Adoption means a session emits an operation and a performance window before the app exits.
Bruno owns this prototype measure and the `neon-stack-performance` dashboard.
Existing Logfire records provide the source of truth. This prototype adds no PostHog event.
The producer emits one window per five seconds and selected gameplay operations.
Its properties contain numeric measurements, bounded mode names, and random session IDs.
They contain no player identity, free-form content, or credentials.
Export failures can create gaps. The prototype does not promise exactly-once delivery.


## MetricKit 27 experiment

`MetricKitReports` consumes Apple's asynchronous daily metric reports on OS 27.
The game retains this reader when its development configuration is enabled.
It exports `game.field.metal_frame_rate` for the full day and selected rendering states.
The bridge converts Apple frequency and duration units to hertz and seconds.

```swift
let fieldReports = MetricKitReports(serviceName: "my-game",
    configuration: try .development(),
    stateDomains: ["my-game.rendering"], metadataKeys: ["quality"])
```

Retain the reader while the app runs. Call `stop()` to cancel it.
Reports carry their historical measurement interval and reported application version.
They omit the current build ID and session ID. Reports can cover multiple versions.
The deterministic `report.id` helps identify repeated deliveries. The client does not deduplicate them.
Full-day and state records overlap. Compare their scopes separately.
The reader does not export diagnostic stacks, player identities, region, or arbitrary state metadata.

Tests decode a synthetic report through Apple's real Codable API and the OTLP span pipeline.
Real daily delivery and physical iOS runtime remain unverified. Apple controls report timing.
Direct export removes the Mac relay requirement. Physical iOS delivery remains unverified.
The current scope covers trusted developer and manual tester builds. Public player telemetry is outside this experiment.
The reader produces historical structured spans. It does not create OpenTelemetry metric instruments.

The **NeonStack** scheme supports ordinary debugging and direct app telemetry.
Disable **Debug executable** in the scheme editor for runs without LLDB.
Use matched Release replays for performance comparisons. Debugger pauses can distort frame windows.
Use `xcode-native-observe attach --latest` for selected live Apple measurements.
