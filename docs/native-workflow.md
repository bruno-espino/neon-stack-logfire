# Native build and performance workflow

The Swift SDK and one native companion form the current development workflow.
The companion uses Xcode result bundles, Apple's Metal performance history, and optional Instruments CPU profiles.
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

The local check and install scripts use the compiler and SDK from one full Xcode installation.
They honor `DEVELOPER_DIR`. Without an override, they use the selected Xcode or fall back to `/Applications/Xcode.app` when Command Line Tools are selected.
They require Xcode 27 or newer and print the chosen directory before compilation.
For another installation, use:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer tools/check-dev.sh
```

This changes only that command's environment. It does not change the system selection.
Apple documents both the system selection and the per-command override in [Configuring command-line tools settings](https://developer.apple.com/documentation/xcode/configuring-command-line-tools-settings).
The MetricKit Swift report tests execute on macOS 27 or iOS 27. They explicitly skip on older runtime systems.
A new SDK does not supply a new runtime framework on an older Mac.

```sh
logfire-apple configure --region us
logfire-apple doctor --send
```

Configure each tester Mac with its own project write token through the hidden prompt.
Do not put a token in the repository or application. SDK runtime export needs `LOGFIRE_DEV_DIRECT=1`.
Companion commands use the shared credential file directly.
`doctor --send` exports one `apple.telemetry.check` record and prints its check ID and delivery counters.
It returns exit 2 when credentials are missing or the exporter does not acknowledge the check.
Configuration alone does not verify ingestion. The write token does not need MCP management permissions.
Credentials remain in a private runtime file. Configuration is shared by the SDK and companion.
Prototype users must run `configure` again. The retired prototype credential location is no longer read.
The supported default is `~/.config/logfire-swift/credentials.env` with permissions `0600`.
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

The default command checks repository files, artifact-script formatting, game logic, audio decoding, Swift tests, and an incremental macOS Debug build.
It reuses `tmp/DerivedData-macos`. It does not install a Release companion or launch the game.
The optional smoke run uses the offscreen reference renderer for 12 seconds. It retains complete SDK windows and host samples.
It does not verify display presentation.
It skips native capture and performs no baseline comparison. A successful smoke run does not establish a performance budget.
The script uses the freshly built Debug companion. SDK and tool edits do not require repeated Release installation.

The repository checker validates local Markdown links, known credential patterns, dashboard JSON, metric columns, and source fingerprints.
It does not validate hosted dashboard SQL. Run authenticated query checks when dashboard queries change.

Keep all Swift unit tests. Scenario fixtures also compile and exercise a small app protocol.
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
Host samples remain available in `host-samples.json`. Detailed records retain attributes.
Native OTel gauges also publish host CPU load and nonfree memory.
The companion pauses its host sampling while it processes a test capture. It does not promise coverage during that processing phase.

## Record a short CPU profile

Build Release, run the app, then record a live interval:

```sh
logfire-apple profile --seconds 5 --service neon-stack
```

The companion verifies the latest SDK session before attaching `xctrace`.
It uses Apple's Time Profiler template for targeted CPU samples.
Apple starts CPU-busy investigations with Time Profiler in its [responsiveness workflow](https://developer.apple.com/videos/play/wwdc2026/268/).
Game Performance Overview combines CPU and Metal recording and remains useful for longer investigations in Instruments.
The default duration is five seconds. Use `--seconds` for an interval between one and thirty seconds.
Remove `--service` when only one instrumented application runs.
Use `--no-telemetry` for local evidence. The command leaves the application running.
CPU samples require an active recording. Retained Metal history cannot recover previous CPU stacks.
The command is optional. It does not run during Command-R, builds, or the default development check.

Each capture directory retains `Instruments.trace`, XML exports, available dSYM files, and an artifact-checksum manifest.
Open `Instruments.trace` in Instruments for the full CPU call tree and timeline.
Raw recordings can contain environment data, source paths, stacks, and system context. Keep them private when sharing artifacts.
Logfire receives the selected process's CPU summary and at most twenty leaf functions.
It also receives up to twenty caller paths for each main/background thread scope.
Each path preserves the sampled caller hierarchy. Unresolved frames and truncated stacks remain explicit.
The export omits raw environment data, source paths, addresses, and full stacks.
Function names, image identities, build/session identity, measured dates, and the local artifact location are exported.
The process identity in the recording must match the selected session before export.

| Record | Selected evidence |
| --- | --- |
| `game.profile.capture` | Local artifact location, checksums in the local manifest, binary identity, template, and actual interval |
| `game.cpu.profile` | Running sample count, total sampled CPU weight, identified main-thread weight, unresolved count, and summary availability |
| `game.cpu.function` | Rank, leaf symbol, image identity, sample count, sampled CPU weight, and fraction of all selected running weight |
| `game.cpu.call_path` | Main/background scope, caller-to-leaf frames, rank, sampled weight, scope fraction, and partial-path flags |

The parser resolves Apple's XML references and selects only the target PID's Running samples.
A leaf function's weight is self weight. Caller time does not enter that function's total.
Unresolved samples remain in the denominator. The top twenty fractions need not sum to one.
Main-thread identification uses Apple's thread label. Other running threads remain in the total.
Sample weights estimate sampled running CPU work. They do not measure wall time, frame latency, or waiting-thread time.
Zero running samples or a decoding gap returns exit 2. Available raw evidence remains local.
Recording, export, or identity failures return a failure and retain available artifacts.
Exporter acknowledgements describe delivery separately from capture success.

Profiling adds overhead. Profiled intervals are diagnostic evidence, not baseline comparison inputs.
Apple recommends Time Profiler for CPU busy work. Waiting, thread scheduling, and actor contention require other instruments.
See [Apple's WWDC26 responsiveness workflow](https://developer.apple.com/videos/play/wwdc2026/268/).
Instruments 27 also offers flame graphs, top-function views, and recording comparisons for the full local analysis.

## Capture and inspect a GPU workload

Enable `MTL_CAPTURE_ENABLED=1` in a dedicated diagnostic launch or Xcode scheme.
This loads Apple's capture framework into the app. It is separate from normal performance measurement.
Run the app with the Swift SDK, then use:

```sh
logfire-apple gpu-capture --profile --service neon-stack
```

The companion verifies the SDK process and asks `gpucapture` to capture one boundary completion.
A layer boundary represents a frame. A queue or device boundary represents a command buffer.
Use `--count 1` through `--count 3` to bound collection.
Apple selects the default boundary. Supply `--boundary ID` or `--label NAME` to resolve multiple layers or queues.
Use `xcrun gpucapture boundaries --pid PID` to inspect the verified target's available boundaries.
Capture fails clearly when the app is not capturable. Ordinary SDK setup does not enable GPU capture injection.

Capture retains `Frame.gputrace`, available symbols, raw inspection output, and a checksummed manifest.
The command leaves the app running. It creates and terminates its own GPU debugger sessions with `--oneshot`.
Static inspection works after capture. Add `--profile` to replay and profile the captured workload.
Replay profiling requires supported hardware. This path is verified on Apple M4.
The command uses the default GPU state and overlapping execution. It does not force a high clock state.
Wait for Metal to produce a renderer window before capture. The SDK session marker can exist before GPU capture is ready.
Replayer preparation and profiling add time beyond the captured frame. They do not run in default development checks.

Logfire receives `game.profile.capture` and selected `game.gpu.replay` records.
The current selection contains at most three cost-ranked encoders and three cost-ranked shaders.
Each row retains its encoder or shader scope. Overlapping costs must not be summed across scopes.
Apple ranks each scope separately. The retained selection is not a complete shader or encoder inventory.
Encoder rows contain replay duration and cost fraction.
Ranked shader rows contain cost fraction, stage, registers, spills, and instruction counts when available.
Apple does not provide active time in the ranked shader properties.
The `Wait` shader property is a wait-instruction count. It is not CPU waiting time.
Replay timing is not live frame latency, current GPU utilization, or a performance baseline.
Raw shader source, buffers, textures, and complete property dumps remain local.

Apple sometimes reports command errors in output while returning exit 0.
The companion collects the profile, then reloads embedded results before reading measurements.
The companion validates JSON and required measurements. Unsupported or incomplete summaries remain observation gaps with exit 2.
Apple can acknowledge profile collection but retain no usable cost tables. This remains an observation gap, even after profile reload.
Capture failures retain available output and return a failure. Exporter status remains separate from capture completeness.
See Apple's [Metal tools for scripts and agents](https://developer.apple.com/metal/tools/).

## Run an app-owned scenario

The SDK, build, profile, capture, and run commands work across instrumented macOS applications.
The new `run` command does not select a game or generate its inputs.
A JSON definition selects the app's scenario, arguments, environment, and renderer-evidence requirement.
The app owns the actions and success assertions. The runner owns process lifetime, identity, host samples, and evidence collection.

```sh
logfire-apple run --app tmp/DerivedData-macos/Build/Products/Debug/NeonStack.app \
  --scenario examples/neon-stack/scenarios/log-roll-two-mazes.json
```

This Log Roll adapter uses seed 777 and 65,536 particles.
It clears two mazes with the existing autopilot. It then rolls onto a fire grate and waits for the normal loss rule.
The adapter does not set the score or force game-over. Its assertions require two clears and the expected loss location.
The verified SDK-only run completes in about 12 seconds. This is a workflow check, not an optimization baseline.

The runner defaults to a 20-second scenario deadline. It stops early after a valid terminal assertion.
The app publishes SDK identity into a private directory for this run.
`DevelopmentScenario.record(window)` declares renderer readiness after a complete SDK window.
Other apps can call `markReady()` when their own startup condition is satisfied.
The app calls `finish(passed:details:)` on a background queue after it checks its scenario assertions.
The SDK flushes queued telemetry before it publishes completion. The runner then terminates and reaps its process group.
Ordinary Command-R does not activate this protocol.

With `--profile cpu`, a worker records a five-second Time Profiler interval while the runner continues app polling and host samples.
The app keeps its own 20-second deadline. The recorder command has a separate 65-second limit for setup, recording, and finalization.
The companion reaps the app, waits for recorder finalization, and then exports and decodes the capture.
Each `xctrace export` command has a 30-second limit. Optional profiling can therefore extend the total command beyond the app deadline.
One signal scope stays active until these owned commands finish. Ctrl-C cancels their process groups and returns exit 130.
An interrupted recording does not start analysis or publish a complete profile manifest. Available raw evidence stays local.

The report separates these durations:

- `app.duration_seconds` covers app launch through reaping.
- `profile.finalization_wait_seconds` covers the recorder join after app reaping. It is zero when no CPU recording starts.
- `profile.record.command_duration_seconds` in the capture manifest covers the recorder command, including its setup and finalization.
- `profile.analysis.duration_seconds` covers export, decoding, and evidence publication.

Recording and app execution overlap. Do not add the full recorder duration to the app duration.
The worker carries a separate OTel context wrapper. Recording, analysis, selected CPU evidence, and the final summary share the run trace.

The definition uses schema version 1, `id`, `arguments`, `environment`, and `require_frame_windows`.
The runner reserves telemetry credentials, session identity, and Metal injection settings.
An unrecognized scenario or missing assertion cannot pass because the process exits successfully.
Malformed status, stale identity, absent required windows, abnormal exit, and late completion fail the run.
A fast app can publish its final assertion between polls. The runner checks its retained marker against the launched PID and process start time.

Add `--profile cpu` to request one five-second Time Profiler recording after readiness.
The recording phase includes tool setup and artifact finalization. Its wall duration exceeds the requested sample interval.
The runner continues one-second host sampling while the recording command runs.
Add `--profile gpu` for one capture during play. The runner enables Metal capture for that diagnostic launch.
Add `--profile shader` to enable Metal HUD shader measurements for this launch.
After the app exits, the companion collects retained `metalperftrace` history and decodes its JSON timeline.
It exports shader compiler counts and time beside presentation measurements for each native update window.
This path adds no live log collector. It retains the original process interval and rejects binary changes during analysis.
The trace contains a `development.shader.analysis` child under the existing run.
Missing compiler timeline fields produce an observation gap. Missing fields do not become zero.
The [SDK-free Metal probe](../examples/metal-shader-probe/README.md) demonstrates the same runner handshake without the Swift SDK.
The runner stops and reaps the app before either profiler analyzes the saved artifact.
CPU analysis exports Instruments XML, validates the original process and actual interval, ranks leaf functions, and sends summaries to Logfire.
It also ranks inclusive functions for each main/background scope. Each function counts once per sample, including recursive occurrences.
The weights overlap. They must not be summed or interpreted as wait time.
`diagnose` can recover this information from older retained exports after it checks their hashes and recording identity.
The [SwiftUI CPU case](cpu-investigation.md) verifies a fixed-seed comparison without adding a profiler to the default development check.
`app.duration_seconds` excludes that analysis. `profile.analysis.duration_seconds` reports its separate cost.
The trace contains timed `development.cpu.record` / `development.cpu.analysis` or `development.gpu.capture` / `development.gpu.analysis` children.
The capture retains the original session/build identity, binary hash, recording, and available symbols.
Offline analysis uses that retained identity. It does not search for a new running app or require the original process to remain alive.
Only one profiler is selected per run. No profiling runs by default.
Use a Release build for optimization investigations.
Profiler collection and decoding have separate bounded durations. They can extend command time beyond the scenario deadline.
The app must still publish completion within its scenario deadline.
Instrumented windows must not serve as ordinary performance baselines.
Native frame-presentation lookback remains available through the separate `capture` command.

Host samples carry their measurement times. GPU capture can briefly interrupt host sampling.
CPU recording uses the existing command poll callback to continue host sampling. It does not start a second observer or daemon.
CPU export/decoding and GPU replay start after the app stops. Host sampling stops with the app.
Collection still adds profiler overhead. This split does not make instrumented windows valid performance baselines.
Readiness time is the runner observation. A terminal assertion supplies an upper bound when an app finishes between polls.
The private report includes app outcome, session/build identity, binary hash, scenario inputs, renderer-window count, host evidence, profile directory, and delivery counts.
Raw captures and local reports remain on the developer's Mac. SDK events export directly when credentials are available.
The companion exports host samples and `development.run` / `development.run.summary` records with the same app session and scenario IDs.
Missing credentials or incomplete optional profiling produce observation gaps with exit 2. Use `--no-telemetry` for an intentional local run.
Timeout uses exit 124. App process failures preserve their exit code. Protocol failures return 1.
Successful assertions and complete requested evidence return 0.
The report status distinguishes a failed app that exits 2 from incomplete requested evidence that also exits 2.
The existing `test-game` action remains the Neon Stack performance-comparison adapter.

Renderer windows alone cannot identify expensive SwiftUI or other main-thread code.
`cpu_frame_p95_ms` remains a compatibility alias for preparation wall time. It does not measure the whole CPU or main thread.
Frame reports now include `cpu_frame.scope=frame_preparation_wall_time` and `main_thread.measured=false`.
Use CPU or SwiftUI profiling to identify code. Timing signals alone cannot name the expensive function.

The SDK provides an opt-in main-thread window independent of renderer completion.
Enable it with `AppleMonitoring(responsiveness: true)`. The reference game enables it.
It measures main-thread CPU-time deltas and main-queue response delay separately.
Queue delay includes CPU work, blocking, and scheduler contention.
The monitor retains the maximum pending delay and permits one outstanding probe.
The controlled [responsiveness example](../examples/responsiveness-probe) validates CPU work against blocking.
Log Roll sums multiple GPU stage durations for its SDK window.
`gpu_time.scope=sum_of_command_buffers` identifies that sum. It does not measure a critical-path frame deadline.
See Apple's [SwiftUI performance analysis](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).

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
Detailed samples and task totals retain attributes. Native OTel instruments also publish build duration/outcomes and host gauges.
The older Python metric names remain historical data.
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
SDK callback rate, SDK drawable presentation cadence, and native frame timelines describe different scopes.

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

## Diagnose a scenario run

The generic `run --app APP --scenario FILE` command includes a `diagnostic` object in its existing `report.json`.
The report combines complete renderer windows, retained responsiveness windows, CPU caller paths, artifact locations, and observation gaps.
The SDK retains responsiveness windows only when the runner supplies an identified development scenario.
These small writes occur on the monitor queue. Normal Command-R sessions do not acquire another local recorder.

```sh
logfire-apple diagnose --report PATH/TO/report.json
```

This command rebuilds the local diagnosis. It does not launch the application, record another profile, or export telemetry.
For onscreen full windows, `presentation_cadence_gap` selects rates below 80% of callback cadence after an allowance for unavailable timestamps.
It requires at least ten valid presentation intervals and excludes capped sample windows.
Intentional presentation limits also produce this finding. It does not identify a GPU bottleneck or count missed refreshes.
Use [the controlled presentation probe](../examples/presentation-probe/README.md) to verify this distinction.
The local `diagnostic.gpuReplays` array includes each accepted GPU capture's identity, replay mode, and selected encoder and shader measurements.
Each capture has at most three encoders and three shaders. Empty or invalid evidence leaves an observation gap.
Replay costs describe captured workloads. They do not measure live utilization, presentation latency, or CPU waits.
Logfire keeps these measurements in separate `game.gpu.replay` records. The hosted diagnostic overview does not duplicate them.
It can recover caller paths from older CPU XML exports after verifying their checksums, process identity, and recording interval.
It preserves the original run status and delivery counters. Reanalysis does not retroactively repair a failed observation or upload.
It cannot recover CPU stacks that no tool recorded.

Import a completed native recording into the same report:

```sh
logfire-apple diagnose --report PATH/TO/report.json --trace PATH/TO/Instruments.trace
logfire-apple diagnose --report PATH/TO/report.json --trace PATH/TO/Instruments.trace --publish
```

The first command stays local. The second explicitly publishes the imported summary and selected syscall records.
Each import creates a new capture ID. Do not add overlapping imports together.
The importer requires the original `sessions/PID.json` marker beside the report.
It checks the recording's target PID, executable path, session identity, and overlap with the retained app lifetime.
It rejects multiple recording runs and ambiguous or missing `thread-state` and `syscall` tables.
The import does not independently verify the recording's binary hash. That hash remains the retained report's attribution.
The importer preserves raw exports with checksums. Later diagnosis verifies and decodes them again instead of trusting a cached summary.

`diagnostic.threadTimelines` retains main-thread state totals and unobserved time for each capture.
It also retains at most twenty longest non-running intervals and twenty syscall summaries.
State intervals are clipped to the overlap between the recording and the app lifetime.
Each capture also correlates at most twenty SDK investigation windows with every decoded main-thread state interval.
The calculation does not use only the twenty retained longest intervals.
`diagnostic.threadTimelines[].windows` preserves the requested SDK period, state durations, observed time, and coverage fraction.
Coverage divides observed native state time by the full requested SDK window duration. Missing coverage is unknown.
Overlapping SDK windows remain separate. Do not add their state durations together.
The SDK's windows are coarse observation periods. Temporal overlap does not identify an exact stalled frame or establish causation.
New renderer report files include session and PID identity. Legacy files remain readable but cannot supply automatic renderer correlation.
Invalid optional renderer or queue files leave correlation gaps. They do not discard valid native state evidence.
Syscall summaries include only complete calls inside that interval. Boundary omissions and missing Wait Time fields remain explicit.
The parser reads columns by their exported schema positions. Sentinels and XML references do not change column positions.
Apple's combined `ThreadActivity` table nests state evidence under syscall rows. Summing only its state-named rows loses some blocked time.
The importer therefore reads the dedicated tables discovered in the recording's table of contents.

Blocked time includes normal timer sleeps and event-loop waits. It does not establish a hang or name a lock owner.
Runnable and preempted time can reflect host contention. External host load must be considered before comparing timings.
Syscall wall time and Apple's Wait Time field overlap thread states. Do not add these measurements together.
Thread timelines remain diagnostic evidence. They do not create a performance gate or infer GPU scheduling and frame deadlines.

The same import reads Apple's optional `ca-client-buffer-wait-interval` table when the recording contains it.
`diagnostic.threadTimelines[].drawableWaits` identifies next-drawable waits on the selected PID and native main-thread ID.
Capture totals include complete calls. Boundary calls are counted as omissions.
`windows[].drawableWaitMilliseconds` clips every selected wait interval to each SDK window, including boundary calls.
Wait durations overlap thread states and syscalls. Do not add these measurements together.
Missing, invalid, or checksum-mismatched wait exports leave a gap and preserve valid thread states.
Only a validated table with no selected calls reports zero observed waits.
These waits identify requests for an available drawable. They do not identify GPU saturation or prove a missed presentation deadline.
Raw exports remain local and retain checksums for later diagnosis.

Logfire receives `development.thread.timeline` with a queryable `timeline.details` object.
Separate `development.thread.syscall` records preserve syscall counts, wall time, and measured Wait Time coverage.
`development.thread.window` records show native states inside identified SDK investigation windows.
Their optional `window.drawable_wait_ms` field retains clipped next-drawable wait time.
`development.metal.drawable_wait` records retain complete-call counts, wall time, longest time, and boundary omissions.
These records retain the native measurement interval, capture ID, session ID, and available build identity.
The offline import has its own analysis trace. `source.run_trace_id` identifies the original run when available.
It does not recreate a parent span that the retained report did not save.
`--publish` returns exit 2 if the exporter does not acknowledge all imported records. The local evidence remains available.
Raw syscall arguments, backtraces, thread wakeup identities, and complete recordings stay local.

Query the imported details in Logfire:

```sql
SELECT attributes->>'capture.id' AS capture,
       attributes->'timeline.details'->'statesMilliseconds' AS states_ms,
       attributes->'timeline.details'->'syscalls' AS syscalls
FROM records
WHERE span_name = 'development.thread.timeline'
ORDER BY start_timestamp DESC
LIMIT 100
```

The controlled Xcode 27 probe confirms all fifteen intentional timer-sleep syscalls and the native main-thread ID.
This validates decoding and attribution of that probe. It does not establish a game defect or an optimization result.
Its retained report fixture uses the probe's logged process identity and timestamps. It is not an SDK game-session capture.
The short game capture attempts did not produce a valid finalized recording within their budgets.
Trace finalization spent substantial time compressing data after the probe exited.
Live captures and comparisons were then paused because the developer reported heavy host CPU use.
Default Command-R, scenario deadlines, and development checks remain unchanged.
The real Log Roll experiment confirms native states and next-drawable waits inside a partial SDK investigation window.
The instrumented recording covers about 44% of that window. Host load remains uncontrolled.
GPU scheduling and complete presentation timelines still require validated decoding. Next-drawable waits do not supply those timelines.
For this experiment, Metal System Trace also included the Thread Activity and System Call Trace instruments.
Its default template did not contain the dedicated `thread-state` and `syscall` tables required by this importer.
Native recording finalization belongs to the `xctrace record` process.
CPU recording now uses a worker with shared cancellation ownership and separate app/recorder deadlines. CPU decoding follows app reaping.
Concurrent System Trace and GPU recording still need this lifecycle integration.
The command runner changes process-wide signal handlers. Concurrent commands must share one cancellation scope.
The experiment finalized its recorder independently after the normal scenario runner stopped its app.
This validates the System Trace recording path. Its unattended lifecycle still needs shared cancellation and cleanup checks.
Direct executable launches on this Mac sometimes create no SwiftUI window, even while SDK queue probes remain responsive.
Opening the owned private app copy through the native app UI restored rendering and passed the game assertions.
Changing the bundle ID alone did not solve the direct-launch case.
The runner needs a native app-launch integration before this recording path becomes an unattended scenario option.
Apple's [NSWorkspace launch configuration](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration) supplies explicit instance, URL substitution, environment, and argument controls.
The current runner still owns and reaps a directly launched child. Preserve that ownership contract during a launcher change.

The diagnostic thresholds select investigations. They do not define performance gates.
The report counts callback intervals above 25 ms and main-queue delays above 100 ms.
High main-thread CPU in a delayed window suggests Time Profiler analysis.
Low or unavailable CPU suggests System Trace or Swift Concurrency analysis.
The five-second CPU average does not prove what the thread did during a brief stall.
Startup, scheduling, locks, and I/O can all affect probe delay.
Each finding retains the affected five-second measurement intervals. These intervals are not exact stall timestamps.
The report never labels GPU command sums as utilization or presented-frame latency.
Time Profiler startup can miss a short app's useful interval. Its finalization now has a separate bounded wait after app reaping.
The runner reports missing requested evidence as incomplete with exit 2. It does not extend the default app deadline or retry automatically.

Apple recommends [call-tree views](https://developer.apple.com/documentation/xcode/analyzing-cpu-profiles-with-call-tree-views)
and a [diagnostic flow for responsiveness](https://developer.apple.com/videos/play/wwdc2026/268/).
Caller paths retain at most 256 frames. The report marks deeper or unresolved paths as partial.
Each scope keeps up to twenty paths. Their fractions include all running samples in that main/background scope.
Recursive frames remain separate positions. Path fractions are not inclusive function weights or chronological timelines.

Logfire receives `development.diagnostic.summary`, selected `development.diagnostic.finding` logs, and `game.cpu.call_path` logs.
The overview omits duplicate caller stacks. The path records retain the structured frames separately.
JSON schema metadata lets Logfire decode these attributes as objects and arrays.
For example, query the structured summary directly:

```sql
SELECT attributes->'diagnostic.details'->'observations' AS observations
FROM records
WHERE span_name = 'development.diagnostic.summary'
ORDER BY start_timestamp DESC
LIMIT 10
```

See Logfire's [attribute serialization](https://pydantic.dev/docs/logfire/instrument/typescript/packages/logfire/#attribute-serialization).
The dashboard tables include trace and span IDs for [native drilldown](https://pydantic.dev/docs/logfire/observe/write-dashboard-queries/#linking-to-the-live-view).
Full recordings remain local. A local artifact path does not provide shared artifact storage.

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
Use `profile` for targeted Time Profiler CPU samples. Use Game Performance Overview in Instruments for broader CPU and Metal investigations.
Use System Trace or Swift Concurrency in Instruments for scheduling, blocking, and actor contention.
Retained Metal history does not supply a complete CPU stack profile.
Apple can collect historical data after an app exits. Manual capture still requires a live verified session for attribution.
The shader scenario path analyzes the runner's own verified and reaped process within its retained lifetime.
`test-game` already automates the run, collection, JSON extraction, and summary export before stopping its app.
Full captures and symbols stay local. Only selected measurements and capture metadata reach Logfire.
No scheduled or CI game-test pipeline is configured. The command is an on-demand pipeline.
MetricKit reports remain delayed evidence inside the SDK.
They cannot replace immediate automated-test measurements.

Next, add general finished-session artifact import and select the next instrument from a real optimization question.
Shader compiler evidence is available through the existing native timeline decoder.
GPU counter sampling remains deferred. It requires supported counters and can perturb the workload.
See Apple's [GPU counter sampling guidance](https://developer.apple.com/documentation/metal/sampling-gpu-data-into-counter-sample-buffers).
A second tester Mac, physical iOS delivery, and performance-budget calibration remain later validation.
Evaluate a smaller compiled build-identity helper to reduce the script's incremental build overhead.
Keep the tester report button deferred until this workflow is stable.

## Logfire dashboard

Import [apple-development.json](../dashboards/apple-development.json) through Logfire's custom dashboard JSON option.
An assistant with Logfire MCP dashboard permissions can also pass this definition to `dashboard_create`.
Use `Apple Development Workflow` as the name and `apple-development-workflow` as the slug.
Supply your own project. The template contains no project IDs, credentials, or recorded session IDs.
Management credentials belong to the dashboard client. The application needs only its project write token.

The twenty-eight panels query diagnostic `records` and native OTel `metrics`.
They cover SDK windows, CPU/queue signals, live Apple measurements, host context, CPU profiles, captures, and builds.
Four native tables show capture-wide states, SDK-window coverage, syscall summaries, and next-drawable waits.
They preserve missing fields and coverage. They do not sum overlapping windows or infer synchronization owners.
Offline imports retain their original measurement dates. Select the recording's time range to view these tables.
The Session selector discovers recorded sessions in the selected range, including native-only imports. All disables its filter.
Build accepts an exact ID. An empty Build value disables its filter.
Build filtering joins the investigation by identity without a SQL join or matching unrelated trace IDs.
The build table ignores Session because the build command and application have different session IDs.

SDK charts use the recorded window end. Apple layer charts use the native measurement end.
Timestamp casts retain UTC. Charts use five-second buckets with visible observation points.
Host charts use the host sample date. Process-memory charts use export time because native process dates are absent.
The SDK timing chart shows the worst window p95 per bucket. It is not a session percentile.
Apple timing points average reported interval means. They are not per-frame session means.
The live FPS chart divides presented frames by measured duration within each session and layer.
Capture tables retain process, layer, and state-layer scopes separately. Overlapping captures are not summed.
The shader table uses `shader_compiler_update` rows and preserves their native dates, layer identity, and trace links.
It includes quiet windows. It excludes cumulative process totals and overview delta fields.
Overview delta fields describe the last update. They do not describe the whole capture.
Shader compiler time uses seconds in exported attributes. The table converts it to milliseconds.
That time measures backend compilation, not the app's complete library or pipeline call.
Pipeline reuse can bypass the compiler without increasing cached compiler events. HUD also creates its own pipelines.
CPU tables retain each capture separately. They show sampled running work, top leaf functions, and selected caller paths.
They do not reconstruct the complete inclusive call tree or a chronological timeline.
CPU rows include the actual recording dates and retain unresolved-sample counts.
Missing attach data means no observation occurred. It does not mean zero load or zero FPS.
Native tables show at most 100 rows. Charts show at most 10,000 recent rows across all series.
Narrow the time range for detailed investigation.

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
| `logfire-apple` | Optional native executable for configuration, builds, attach, capture, CPU profiling, and analysis | No |
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

Evaluate a generic build-identity helper and explicit build-script dependencies after measuring Command-R overhead.
The current measured identity phase takes about half a second on the development Mac. It is not the dominant build cost.
The current script runs on every build and hashes package sources beyond the linked SDK.
Measure each change with build timing summaries before replacing the script.
Follow Apple's [incremental build guidance](https://developer.apple.com/documentation/Xcode/improving-the-speed-of-incremental-builds).
Then add async span support with task-context tests and finished-session artifact import.
The native metric exporter is verified for delta temporality and source identity.
It remains a development prototype alongside the upstream experimental HTTP exporter.
Keep longer tests, iOS Simulator validation, and the tester report button deferred during this macOS iteration.

## Metric and trace semantics

The configured SDK exports both `/v1/traces` and `/v1/metrics` through native OTLP HTTP.
The [metric catalog](telemetry-metrics.md) lists the nineteen fixed instruments.
Events and window summaries use Logfire logs. A window log appears at its measurement end time.
Its attributes retain the interval start and end. It does not claim that interval as an operation duration.
Explicit `withSpan` operations keep their real durations and native signposts.

The scenario runner passes W3C trace context to the launched app.
SDK logs, host samples, profiler evidence, and the final summary belong to the run trace.
Builds have separate traces. Embedded build ID and build trace ID connect them to sessions.
A manual Cmd-R session has no runner parent. Its operations remain separate traces with shared session/build identity.
The build task table reports aggregate parallel task costs. It cannot reconstruct build critical paths.
