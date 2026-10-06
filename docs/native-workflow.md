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
Use runs of 60 seconds or longer to reduce the relative effect of native slice boundaries.
A threshold is an experimental budget. Repeated runs must establish measurement noise before CI enforcement.

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
MetricKit reports remain delayed evidence inside the SDK.
They cannot replace immediate automated-test measurements.

Next, validate a second tester Mac and physical iOS report delivery.
Establish repeated-run baselines before enforcing a CI performance budget.
Add an artifact-import path for finished sessions and iOS captures.
Evaluate a smaller compiled build-identity helper to reduce the script's incremental build overhead.
Keep the tester report button deferred until this workflow is stable.
