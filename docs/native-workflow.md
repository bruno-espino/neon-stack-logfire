# Native build and performance workflow

The Swift SDK and one native companion form the current development workflow.
The companion uses Xcode result bundles and Apple's Metal performance history.
It does not start a daemon or call Python.
The tester report button remains deferred.

## Install once

From this repository, run:

```sh
tools/install-companion.sh
```

The script installs a Release executable at `~/.local/bin/logfire-apple`.
Set `LOGFIRE_APPLE_INSTALL_DIR` to choose another directory.
Add the directory to PATH if needed. The installer does not modify shell profiles.
The executable works outside the source checkout.
Repeat installation to update it. Signed release distribution remains future work.

```sh
logfire-apple configure --region us
logfire-apple doctor
```

Credentials remain in a private runtime file. Configuration is shared by the SDK and companion.
Local Apple monitoring can remain active when network export is disabled.
Ordinary Xcode Command-R requires neither the companion nor Python.
It embeds build identity and the SDK exports runtime records when configured.

## Fast development loop

Use Command-R for ordinary game changes. No test session runs automatically.
Use the cached development check when SDK or companion changes need validation.

```sh
tools/check-dev.sh
tools/check-dev.sh --smoke
```

The default command runs the Swift tests and an incremental macOS Debug build.
It reuses `tmp/DerivedData-macos`. It does not install a Release companion or launch the game.
The optional smoke run lasts 12 seconds. It retains one or more complete SDK windows and host samples.
It skips native capture and performs no baseline comparison. A successful smoke run does not establish a performance budget.
The script uses the freshly built Debug companion. SDK and tool edits do not require repeated Release installation.

Keep all Swift unit tests. Their execution takes less than one second on the current Mac after compilation.
Skip iOS Simulator builds during this macOS workflow iteration.
Run a separate iOS compatibility check when a change requires cross-platform validation.
Use a 20-second native session only when validating the capture pipeline.
Longer runs and performance-budget calibration remain deferred.

## What arrives live

| Data | Producer and timing |
| --- | --- |
| App operations and frame windows | SDK during ordinary gameplay. Frame windows cover five seconds. |
| Whole-host CPU load, free/wired/compressed memory, filesystem free bytes | Companion once per second during `attach` or `test-game`. |
| Native process resources and layer performance | Apple's `metalperftrace listen` during `attach`. Selected fields depend on Apple's updates. |
| State-layer aggregations | Companion near the end of `test-game`, before the app stops, or an explicit `capture`. |
| MetricKit reports | SDK when Apple delivers metric or diagnostic reports. They are not an immediate per-frame feed. |

Host sampling does not start during an ordinary Command-R session unless you attach the companion.
Run `logfire-apple attach --seconds 10 --service neon-stack` to observe a manual session.
Host samples use the `game.host.sample` record name and the session/build identity.
Their `measurement.scope` is `whole_host`. CPU utilization is a fraction of total host CPU capacity.
They describe other applications and system work as well as the game.
They do not establish that the game caused the load.
Concurrent companions on the same Mac produce overlapping host samples. Do not add these streams together.
Native CPU time is a separate process measurement. GPU timing is not hardware utilization.

The exporter batches live records. Sampling once per second does not promise instant network delivery.
Host samples remain available in `host-samples.json`. All current measurements use span attributes, not OTel metric instruments.
The companion pauses its host sampling while it processes a test capture. It does not promise coverage during that processing phase.

## Observe a build

```sh
logfire-apple build --scenario neon-release -- \
  -project examples/neon-stack/NeonStack.xcodeproj -scheme NeonStack \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath tmp/NeonStack build
```

The command adds timing summaries and a result bundle unless you supply them.
The app build phase embeds the exact observed build ID and an available build trace ID.
The companion retains stdout, stderr, task totals, issue counts, and timestamped host samples.
`xcresulttool get build-results` supplies issue totals when available.
Task totals are aggregate work durations. They are not timed compiler spans or a critical-path reconstruction.
Host samples use macOS APIs for CPU utilization, free/wired/compressed memory, and filesystem free bytes.
They describe the entire host. They do not establish that the build caused the load.
These samples and build totals use span attributes. They do not duplicate the older Python metric instruments.
Host disk I/O and swap sampling from the earlier Python experiment remain outside this native iteration.

Options include `--output DIRECTORY`, `--scenario NAME`, `--cache-state warm`, `--sample-interval 1`, and `--timeout 3600`.
The cache label records your declaration. It does not clean caches.
The command forwards cancellation to its process group and kills survivors after three seconds.
It preserves Xcode's exit status. A configured timeout returns 124.
Do not run concurrent builds against the same DerivedData directory.
Add `--no-telemetry` for local evidence only.

## Test a controlled game session

```sh
logfire-apple test-game --app tmp/NeonStack/Build/Products/Release/NeonStack.app \
  --seconds 20 --seed 777 --render-mode aurora --aurora-layers 8
```

This command adapts the reference NeonStack game. It is not a universal app automation API.
Benchmark mode controls the seed, mode, and detail. It disables manual input and sound.
The app records five-second SDK windows after a two-second warmup.
The companion reads these windows and exports them once with historical measurement timestamps.
The test app receives no telemetry credentials and performs no network export.

Onscreen tests retain Metal history from app launch through collection. This preserves the initial state transition.
The companion then uses Apple's aggregation offsets to cover the completed SDK window interval.
The current Apple CLI accepts whole seconds. The companion rounds the start down and the end up.
Thus native aggregation can extend each boundary by less than one second. The manifest retains both date ranges.
It compares the state layer whose mode, workload, detail, and size match the SDK windows.
Apple's retained performance slices can shorten the measured interval even when aggregation bounds cover it.
Native summaries retain actual dates. The gate permits at most one second of missing coverage at each SDK interval boundary.
The report includes `native_sdk_interval_coverage`. Larger losses or missing dates remain observation gaps.
Process and full-layer summaries describe the broader recording. They do not enter the interval comparison.
The app stays alive during collection. The command stops only the app it launched.
The capture retains recordings, symbols, checksums, and Apple JSON output.
It also runs Apple's state aggregation for the configured rendering domain.
Logfire receives selected process, layer, and state-layer summaries.
These overlapping summaries must not be summed together.
The SDK and native values describe related intervals. They are not exact samples of the same set of frames.
SDK callback rate and native presented FPS remain separate measurements.

Each session directory contains:

- `report.json`. Cohort, build identity, SDK/native summary measurements, and observation gaps.
- `performance.jsonl`. Original complete SDK windows.
- `host-samples.json`. Timestamped whole-host samples with session/build context.
- `console.log` and `console.stderr`. Local application output.
- `native/manifest.json` and capture artifacts when collection succeeds.

Use `--offscreen` for a paced 600 by 1200 Metal texture workload.
Offscreen tests skip native presentation collection. They do not measure display smoothness.
Use `--no-native` to explicitly run an SDK-only onscreen experiment.
A missing native capture remains an observation gap. The command does not silently treat it as a complete test.
Use `--no-telemetry` to retain all evidence locally.

## Analyze and compare

```sh
logfire-apple analyze --report CURRENT_REPORT
logfire-apple analyze --report CURRENT_REPORT --baseline BASELINE_REPORT \
  --max-regression-percent 10
```

The comparison retains a separate JSON result beside the current report.
A gate requires Release builds and at least three complete windows per run.
Match the device model, memory, processor count, GPU name, OS, seed, duration, test protocol, rendering settings, resolution, and thermal states.
Use the same machine for a valid performance comparison. Device descriptors do not uniquely identify a physical Mac.
The gate rejects mismatched cohorts, observation gaps, and missing measurements.
New slow frames above a zero baseline count as a regression without a percentage division.
A threshold remains experimental. Performance-budget calibration is deferred during workflow development.
Short smoke runs validate data flow. They do not establish reliable performance regression budgets.

| Measurement | Meaning |
| --- | --- |
| `sdk_callback_hz` | Frame-count-weighted harmonic callback rate reconstructed from windows |
| `sdk_worst_window_frame_interval_p95_ms` | Maximum of complete window p95 intervals |
| `sdk_worst_window_gpu_command_p95_ms` | Maximum of complete window p95 Metal command durations |
| `sdk_slow_frame_fraction` | Frames over 25 ms divided by sampled frames |
| `native_presented_fps` | Apple's presented FPS for a single presented layer |
| `native_frame_on_glass_mean_ms` | Apple's mean displayed-frame interval |
| `native_gpu_wall_mean_ms` | Apple's mean on-GPU wall time for presented frames |

Window p95 maxima are not session percentiles.
The native gate currently requires exactly one matching presented state layer.
Multi-layer apps need a declared layer selection rule before comparison.
The comparison does not infer a CPU or GPU bottleneck from these values alone.
A regression needs further analysis in Instruments or the Metal debugger.

Comparison exit codes are 0 for passed, 1 for regressed, and 2 for incompatible or incomplete evidence.
A standalone analysis without a baseline prints measurements without asserting a pass.
Game-test exit 2 records observation gaps. A nonzero application status remains a failure.
Exporter delivery counters remain separate from performance evidence completeness.

## Apple tooling and remaining work

Apple describes JSON overviews for regression testing and automated triage in
[its WWDC26 game performance session](https://developer.apple.com/videos/play/wwdc2026/388/).
Use Game Performance Overview or Metal System Trace in Instruments when CPU stacks and scheduling detail are required.
Retained Metal history does not supply a complete CPU stack profile.
Apple can collect historical data after an app exits. Our companion currently requires a live verified session for attribution.
`test-game` already automates the run, collection, JSON extraction, and summary export before stopping its app.
Full captures and symbols stay local. Only selected measurements and capture metadata reach Logfire.
No scheduled or CI game-test pipeline is configured. The command is an on-demand pipeline.
MetricKit reports remain delayed evidence inside the SDK.
They cannot replace immediate automated-test measurements.

Next, improve the macOS setup and iteration loop.
A second tester Mac, physical iOS delivery, and performance-budget calibration remain later validation.
Add an artifact-import path for finished sessions and iOS captures.
Evaluate a smaller compiled build-identity helper to reduce the script's incremental build overhead.
Keep the tester report button deferred until this workflow is stable.

## Logfire dashboard

Import [apple-development.json](../dashboards/apple-development.json) through Logfire's custom dashboard JSON option.
An assistant with Logfire MCP dashboard permissions can also pass this definition to `dashboard_create`.
Use `Apple Development Workflow` as the name and `apple-development-workflow` as the slug.
Supply your own project. The template contains no project IDs, credentials, or recorded session IDs.
Management credentials belong to the dashboard client. The application needs only its project write token.

The ten panels query `records`. They cover SDK windows, live Apple measurements, whole-host context, captures, and builds.
Session and Build accept exact IDs. Empty values disable the filter.
Build filtering joins the investigation by identity without a SQL join or matching unrelated trace IDs.
The build table ignores Session because the build command and application have different session IDs.

SDK charts use the recorded window end. Apple layer charts use the native measurement end.
Host charts use the host sample date. Process-memory charts use export time because native process dates are absent.
The SDK timing chart shows the worst window p95 per bucket. It is not a session percentile.
Apple timing points average reported interval means. They are not per-frame session means.
The live FPS chart divides presented frames by measured duration within each session and layer.
Capture tables retain process, layer, and state-layer scopes separately. Overlapping captures are not summed.
Missing attach data means no observation occurred. It does not mean zero load or zero FPS.
The tables show at most 100 rows. Charts show at most 10,000 buckets. Narrow the time range for detailed investigation.

The dashboard is an editable copy. Reimport an updated template under a new slug or update the existing definition through MCP.
It does not receive automatic standard-dashboard updates.
Logfire supports [JSON dashboard imports](https://pydantic.dev/docs/logfire/observe/dashboards/)
and [MCP dashboard management](https://pydantic.dev/docs/logfire/guides/mcp-server/).
Standard infrastructure dashboards require their expected metric instruments and names.
Our custom dashboard does not convert span attributes into OTel metrics.

## Package and distribution

Keep one repository during the pilot. Distribute three independent parts:

| Part | Installation | Required for ordinary app telemetry |
| --- | --- | --- |
| `LogfireSwift` | Source Swift package with a versioned library product | Yes |
| `logfire-apple` | Optional native executable for configuration, builds, attach, capture, and analysis | No |
| Dashboard definition | Logfire JSON import or MCP creation | No |

Keep NeonStack under `examples`. It demonstrates the integration and supplies a repeatable workload.
Do not require users to adopt the game, its Xcode project, a relay, Python, or a daemon.
The SDK installation instructions are in [the SDK guide](swift-sdk.md#add-the-sdk-to-an-app).
The library supports macOS 14 and iOS 17. StateReporting and the new MetricKit path require OS 27.
Native lookback requires macOS 27 and its Apple tools.

Before a reusable release, select a license, retain dependency notices, and publish a semantic version tag with release notes.
Add a short package-validation CI job. Keep native performance comparisons opt-in.
Verify installation on a second Mac before claiming a supported distribution.
Then distribute a signed, notarized companion archive with checksums and an installation path such as Homebrew.
The current installer builds from source. No signed download or release pipeline exists.
Follow Apple's [macOS distribution guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

The upstream Swift 2.6.0 release is marked as a prerelease.
Its HTTP exporter remains experimental. Swift traces are stable; metrics and logs remain under development.
Keep the tested exact pins for this pilot. Review upstream changes before each dependency update and release.
See the [release list](https://github.com/open-telemetry/opentelemetry-swift/releases),
[exporter status](https://github.com/open-telemetry/opentelemetry-swift/blob/2.6.0/README.md),
and [language status](https://opentelemetry.io/docs/languages/swift/).

Prioritize a generic build-identity helper and explicit build-script dependencies to reduce Command-R overhead.
The current script runs on every build and hashes package sources beyond the linked SDK.
Measure each change with build timing summaries before replacing the script.
Follow Apple's [incremental build guidance](https://developer.apple.com/documentation/Xcode/improving-the-speed-of-incremental-builds).
Then add async span support with task-context tests and finished-session artifact import.
Evaluate a small metrics exporter separately if standard infrastructure dashboards become a requirement.
Validate delta temporality and source identity before that migration.
Keep longer tests, iOS Simulator validation, and the tester report button deferred during this macOS iteration.
