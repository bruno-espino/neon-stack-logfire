> Ordinary Xcode runs and native captures now use Swift only. See [the root guide](../../README.md).
> Install this optional Python package for full build observation, controlled replays, or relay comparisons.

# xcode-observe

An experimental CLI for Apple build observation. It wraps `xcodebuild`, retains
local artifacts, and exports a build trace with timestamped host samples to Logfire.

## Run a build

From the repository root:

```bash
uv sync --project tools/xcode-observe
set -a && source ~/.config/xcode-observe/credentials.env; set +a
uv run --project tools/xcode-observe xcode-observe \
  --cache-state cold --scenario my-game --sample-interval 0.25 -- \
  -project examples/neon-stack/NeonStack.xcodeproj \
  -scheme NeonStack -configuration Debug \
  -destination 'platform=macOS,arch=arm64' clean build
```

For another machine, supply `LOGFIRE_TOKEN` with a project write token and set
`LOGFIRE_BASE_URL` to your ingest region. A Logfire management API key grants
management access. It is not the SDK write token.

Without a write token, the CLI records locally. Use `--no-telemetry` to disable
export explicitly. The default artifact directory is `.xcode-observe` in the
current directory. Override it with `--artifact-dir PATH`.

## Behavior

- The CLI preserves the build's exit code. Cancellation returns 130 for SIGINT
  and 143 for SIGTERM. It forwards the signal to the build process group.
  After three seconds, it kills surviving processes and reaps the child.
- It preserves separate stdout and stderr streams. A closed consumer pipe does
  not stop the build. It also retains a combined local `build.log`.
- It adds `-showBuildTimingSummary` and an owned `-resultBundlePath` when absent.
  A supplied result bundle path stays effective. The CLI never deletes bundles.
- Each build retains `report.json`, its log, and any result bundle that Xcode creates.
  `xcresulttool` supplies warning and error totals when available.
- The CLI uploads an allow-list of build context. It keeps raw commands, source
  paths, build logs, and result bundles local. Scheme names, Git branch names,
  commit hashes, and host names are part of the uploaded context.
- Host samples describe the whole machine. CPU is a fraction from zero to one.
  Memory uses the operating system's available-memory accounting. Disk I/O is
  cumulative since boot. The CLI does not calculate an I/O rate from one sample.
- Standard CPU, memory, and free-space gauges support host inspection. Each
  timestamped sample also becomes a child log in the build trace. Thus a short
  build's sample history does not depend on the metric export interval.
- Metric dimensions exclude build IDs, trace IDs, Git commits, and run IDs.
  Build spans retain that context for drill-down.
- Initialization, sample export, and final telemetry failures do not replace the
  build result. Export has a bounded flush. Inspect `observation_errors` in the
  local report when telemetry is unavailable.

## Scope and limits

The CLI observes local and CI commands. Builds started inside the Xcode GUI do
not pass through it. Host monitoring stops when the build ends.
Xcode task times are aggregate work across possibly parallel tasks. They are
not a phase timeline or a critical path. The build CLI does not measure GPU frame
times, code signing cost, or an App Store upload.

## Native game profiling and Logfire

The companion `xcode-game-profile` command runs a fixed-seed Neon Stack replay.
It retains five-second frame, CPU, GPU command, and thermal-state summaries.
It exports those summaries as `game.performance.window` records under a
`game.session` span. The launcher reads build identity from the app resource.
Use `--build-trace-id` only to override that automatic relationship.
The game process receives no Logfire credentials. The launcher exports after
the replay ends. It preserves local reports if export fails.

```bash
uv run --project tools/xcode-observe xcode-game-profile \
  --app tmp/NeonStack/Build/Products/Release/NeonStack.app \
  --seconds 20 --seed 777 --render-mode neon
```

Use Xcode and Instruments for detailed diagnosis. `--instruments` records the
Game Performance template locally. Use Logfire to compare repeatable windows
and build context across sessions. Import `runtime-dashboard.json` for this view.
Native signposts cover game updates, hard drops, line clears, and frame encoding.
Callback FPS measures renderer callbacks. GPU command time covers command-buffer
execution. Neither measurement gives presented frame time or the critical path.
Keep profiled sessions separate because Instruments can change performance.

Use `--offscreen` on a CI runner without an unlocked desktop. The replay renders
the same shaders into a 600 by 1200 texture and retains a PNG preview. It paces
the loop at 60 iterations per second. The dashboard's workload field separates
these loop measurements from onscreen callback measurements.

Apple documents the [Game Performance template](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app),
[Metal HUD](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance),
and [GPU command timing](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime).
Logfire supplies [dashboards](https://pydantic.dev/docs/logfire/observe/dashboards/)
and [SQL alerts](https://pydantic.dev/docs/logfire/observe/alerts/).
Establish several comparable baseline runs before enabling regression alerts.

The [Metal game walkthrough](../../examples/neon-stack/README.md)
covers macOS, iOS Simulator, incremental builds, contention, and failure.
Import [dashboard.json](dashboard.json) into the target Logfire project's dashboards.
The comparison table keeps destination, cache state, Xcode version, and Mac model
in its cohort key. Establish a baseline before adding regression alerts.

## Native monitoring and capture correlation

Read [PROJECT.txt](../../docs/PROJECT.txt) for the compact project guide and terminology.
The ordinary NeonStack scheme exports directly without a relay or live observer.
Each build embeds `LogfireBuild.json`. Each app run publishes a private session marker.
Wrapped builds share the observer build ID and trace ID with the app.
Cmd-R embeds build identity through a host Swift script. The app exports it at startup without full build duration.
The session marker connects native Apple measurements to app operation spans.
The observer checks the executable, process start time, and current build identity.

Select **NeonStack** for direct Swift telemetry with normal LLDB debugging.
The app reads the private runtime credential file when `LOGFIRE_DEV_DIRECT=1`.
This opt-in supports trusted developer and tester machines. It does not embed a token in the build.
Apple retains recent Metal history on macOS 27. Capture it while the app runs.
Use `--latest` to select the newest verified live development session.
Use the `attach` action instead of `capture` for explicit live Apple measurements.
Set its `--seconds` option to bound that observation.

```bash
swift run logfire-apple capture --last 10s
```

Apple's `metalperftrace` supplies presented FPS, frame-on-glass intervals,
GPU wall time, and drawable waits. These measurements differ from game callbacks.
The observer retains raw updates locally and exports selected summaries.
The dashboard exposes native measurements, build identities, and capture locations.
A capture contains `.atrc` files, PID-filtered overviews, symbols when available,
and a manifest with session IDs, build IDs, timestamps, and checksums.
The complete Apple recording can include other processes. It remains local.
Logfire receives capture metadata and selected `game.native.capture_summary` measurements.
Shared artifact hosting is not implemented.
StateReporting adds render-mode and workload context with an OS and SDK 27 build.
Older targets retain native signposts and app operation telemetry.
The Swift package includes a MetricKit 27 adapter for selected daily metrics and diagnostic summaries.
It exports selected state metadata and historical timestamps without current-session attribution.
A synthetic Apple-format report passes. Real daily delivery remains unverified.

## Verification

```bash
uv run --project tools/xcode-observe pytest \
  -c tools/xcode-observe/pyproject.toml tools/xcode-observe/tests
xcrun swiftc examples/neon-stack/NeonStack/GameEngine.swift \
  examples/neon-stack/tests/EngineTests.swift \
  -o /tmp/neon-stack-engine-tests
/tmp/neon-stack-engine-tests
```

The tests exercise actual child processes, process-group cancellation, closed
output consumers, retained artifacts, short builds, credential isolation, and
in-memory telemetry. The Swift checks exercise game rules and seeded replay.
The walkthrough requires actual Xcode and its Metal toolchain.

## Project ownership

Status is Experimental. Owner is Bruno. No public integration documentation is
published. Adoption is a completed `xcode.build` span from a configured machine.
The dashboard measures outcomes and duration from telemetry. No separate
PostHog events are added. Build IDs identify builds, not people or accounts.
Uploaded names are explicit developer and CI context.

Build correctness depends on Xcode. Telemetry is an optional side effect. The prototype's reliability checks cover preserved exit
codes, bounded shutdown, and retained reports.
