> Ordinary Xcode runs now stream native telemetry through the experimental
> [Swift integration](../../docs/swift-sdk.md).
> Press Command-R with the NeonStack scheme. Ordinary runs require no Python host-tool setup.
> Use an explicit native attach or capture command when you need Apple profiler evidence.
> The build and replay workflows below remain available.

# Observe a Metal game build

## What this scenario demonstrates

Play Neon Stack, a falling-block game with a Metal renderer. Build it for macOS
and iOS Simulator. Inspect build traces and repeatable gameplay measurements.

## Who this is for

Apple game and app developers who need to investigate build performance on Macs.

## Prerequisites

- macOS with Xcode 27 or later selected by `xcode-select`.
- The Xcode Metal toolchain. If unavailable, run `xcodebuild -downloadComponent MetalToolchain`.
- `uv`, Python 3.14, and a Logfire project write token.
- An iOS Simulator SDK. Signing is disabled for this development example.

## Optional build and replay setup

From the repository root, install the standalone observer:

```bash
uv sync --project tools/xcode-observe
cd examples/neon-stack
cp .env.example .env
# Edit .env with your project's write token and region.
set -a && source .env; set +a
```

For direct app export, create a private credential file as described in
[the SDK guide](../../docs/swift-sdk.md). Keep credentials outside Git.

## Walkthrough

Run five real builds:

```bash
uv run run.py --run-id first-demo
```

The script runs a clean macOS build, an incremental macOS build, a clean iOS
Simulator build, a clean macOS build with four bounded CPU workers, and a failed
scheme lookup. It expects the last build to exit 65. All other builds must succeed.
The workers stop after their build or after 30 seconds.

The script stores reports and `.xcresult` bundles under `.xcode-observe/`.
Reusing a run ID skips completed scenarios. Use a new run ID for another experiment.
Here, `cold` means a project clean build. Xcode, SDK, and operating system caches
can remain warm. CPU samples describe the entire machine.

Open the game after the script finishes:

```bash
open .xcode-observe/*/DerivedData-macos/Build/Products/Debug/NeonStack.app
```

Click the board to focus keyboard input. Use the arrow keys to move and rotate.
Press Space for a hard drop, C to hold or swap, P to pause, and R to restart.
The screen also provides touch and mouse controls.
The first hold stores the current piece and takes the next piece from the queue.
Later holds swap the current piece with the stored piece.
Each swapped piece starts at the top with its original rotation.
You can hold once per piece. Lock the active piece to enable hold again.
The hold preview dims while hold is unavailable. Restart clears the hold slot.
Complete rows to score. The outlined piece shows the landing position.
Use the Classic, Neon, and Aurora selector to change the renderer.
Classic uses flat colors without glow or animated scanlines.
Neon adds colored glow, bright edges, animated scanlines, and a glowing board border.
The selector shows the active mode and describes its effects.
Aurora adds animated green and violet light curtains. Select Low, Medium, or High detail.
These settings draw 8, 24, or 48 layers. Higher detail increases GPU work.
All modes use the same rules, piece queue, controls, and scoring.
Successful rotations, holds, and locks produce short synthesized sounds.
Line clears add a sweep and an ascending chime.
A four-row clear adds a cyan burst and a longer chime.
An ALL CLEAR means a line clear leaves no locked cells on the board.
It adds a gold burst and a fanfare. It can follow fewer than four cleared rows.
These effects do not change scoring or delay the next piece.
Use the speaker button to mute sound. Pause stops active sounds.
Reduce Motion replaces sweeps and bursts with a gentle row fade.
The iOS build produces a Simulator app. This walkthrough does not install it
on a Simulator or sign an app for a physical device.

### Profile a repeatable game session

Build a Release application from the repository root:

```bash
uv run --project tools/xcode-observe xcode-observe --scenario neon-release -- \
  -project examples/neon-stack/NeonStack.xcodeproj \
  -scheme NeonStack -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath tmp/NeonStack build
```

Run the same seeded gameplay in two rendering modes:

```bash
uv run --project tools/xcode-observe xcode-game-profile \
  --app tmp/NeonStack/Build/Products/Release/NeonStack.app \
  --seed 777 --seconds 20 --render-mode classic
uv run --project tools/xcode-observe xcode-game-profile \
  --app tmp/NeonStack/Build/Products/Release/NeonStack.app \
  --seed 777 --seconds 20 --render-mode neon
```

The game plays automatically. Benchmark mode disables manual moves and mode
changes. The recorder excludes the first two seconds and writes five-second
windows. It retains JSONL reports under `.xcode-observe/runtime/`.
Benchmark replays disable sound and include the Metal clear effects.
Pass `--build-trace-id ID` to link a session to its build trace.

Use `--render-mode aurora --aurora-layers 48` for a heavier visual workload.
Compare it with 8 layers on the same Release build, seed, device, and resolution.
The recorder starts a new window when detail changes. StateReporting also records detail.

Add `--offscreen` for a CI-friendly GPU replay. It renders the same board and
shaders into a 600 by 1200 Metal texture. It paces the loop at 60 iterations per
second and retains `board.png` as a renderer preview. This mode does not require
an unlocked desktop. Its loop interval does not measure display presentation.
Compare offscreen runs with other offscreen runs at the same resolution.

Add `--instruments` to record the native Game Performance template. The profiler
retains `GamePerformance.trace` beside the report. Open that file in Instruments.
The profiler sets the retention window to the requested session duration.
This prevents the template's five-second default from removing earlier events.
Inspect `GameUpdate`, `HardDrop`, `HoldPiece`, `LineClear`, `FourLineClear`, `AllClear`, and `EncodeFrame` signposts.
The `HoldPiece` event appears during interactive play. The benchmark does not use hold.
The headless replay emits an `OffscreenFrame` signpost.
Profiled runs can have overhead. Compare them separately from ordinary replays.
For interactive inspection, open the Xcode project and select **Product > Profile**.
You can enable Apple's Metal HUD with `MTL_HUD_ENABLED=1` when you launch the game.

The renderer measures callback intervals, CPU simulation and encoding time, and
completed Metal command-buffer GPU time. Callback FPS is not presented FPS.
A long callback interval is not proof of a dropped presentation.
Window p95 values describe each window. Their average is not a session p95.
GPU time is absent when Metal does not provide it.

### Understand the telemetry path

The build observer creates Logfire spans around `xcodebuild`.
It exports parsed build timings and host samples.
Those spans are observer traces, not Instruments traces.

The game measures callback intervals and CPU frame work inside its renderer.
It reads GPU command-buffer timestamps from Metal after each command completes.
The game writes five-second summaries to a local JSONL report.
The Python profiler exports these summaries as `game.performance.window` log records
inside a `game.session` span after the replay.
The session span covers the export operation, not the gameplay timeline.
Use the report timestamps and elapsed values to locate the measurement windows.
These runtime values are structured logs. They are not native Instruments spans
or OpenTelemetry metric instruments.

The `--instruments` option separately records the Game Performance template.
The local `.trace` includes native signposts and detailed CPU, GPU, and display data.
The profiler does not parse or upload that file to Logfire.
It does not export individual signposts, shader counters, or per-frame native traces.
The NeonStack Xcode scheme exports runtime data during ordinary runs.
The replay command disables that path and exports the retained report once.

### Try the clear feedback

Use a prepared board to exercise each effect through real gameplay.
Set `NEON_FEEDBACK_SCENARIO` to `single`, `four`, or `all-clear` before launch.
From the repository root, launch the Release executable directly and press Space:

```bash
NEON_FEEDBACK_SCENARIO=all-clear \
  tmp/NeonStack/Build/Products/Release/NeonStack.app/Contents/MacOS/NeonStack
```

An offscreen demo hard-drops this prepared piece on its first frame.
It retains a renderer preview such as `all-clear.png` beside the performance report.
Demo previews add capture overhead. Exclude these demo sessions from performance baselines.

## Verify it worked

Open your Logfire project and select **Live**. Filter `service_name = 'xcode-observe'`.
Find `xcode.build` spans for all five `build.scenario` values. Each span includes
the exit code, destination, cache state, duration, and aggregate Xcode task times.
Expand a trace to find timestamped `xcode.host.sample` records.

Select **Hosts** to find the Mac's CPU and memory readings during a build.
The observer samples only while a build runs. It is not a continuous host agent.

Select **Dashboards** and import the observer's `dashboard.json`. Compare runs with
matching scheme, configuration, destination, cache state, Xcode version, and Mac model.
Inspect CPU and memory alongside build duration. Contention does not prove causality.

For runtime measurements, find a `game.session` span in Live. Expand its
`game.performance.window` records. Select **Dashboards** and import
`runtime-dashboard.json` from the observer directory. Compare matching seeds,
drawable sizes, Mac models, and profiling modes. Frame interval, GPU command
time, and thermal state help you choose what to investigate in Instruments.

## Cleanup

Delete this scenario's `.xcode-observe/<run-suffix>/` directory to remove its
local reports and build products. Retained logs and result bundles can contain
source paths and diagnostics. Delete the imported dashboard through Logfire
if you no longer need it. Telemetry follows the project's retention policy.

## Native monitoring workflow

Configure runtime credentials as described in [the SDK guide](../../docs/swift-sdk.md).
Open `NeonStack.xcodeproj`. Select **NeonStack**, **My Mac**, and press Command-R.
The scheme retains LLDB debugging. It starts no relay or native observer.
The build embeds identity metadata. The app publishes a private session marker.
Open **Neon Stack Performance** in the target project's dashboards.
Check **Apple display delivery**, **App build identities**, and **Native captures attached to sessions**.
Run `swift run logfire-apple capture --last 10s` from the repository root.
The capture manifest and Logfire record must contain the same session ID and build ID.
Open the local `.atrc` artifact in Instruments for native analysis.

For live Apple measurements, run this command from the repository root while the game runs.

```sh
swift run logfire-apple attach --seconds 30 --service neon-stack
```

The native companion observes for the selected duration and checks the app identity during updates.
Capture files stay local. They can include other processes in the Apple recording.
The exported overview and live measurements select the game PID.
This scheme sets `LOGFIRE_DEV_DIRECT=1`. The app reads the private runtime credential file on the Mac.
The build does not embed credentials. Configure each trusted tester machine separately.
Capture recent Apple history with `--latest`.
Logfire receives selected lookback measurements after that command.
StateReporting context requires an SDK and OS 27 build.
The SDK owns MetricKit 27 report collection and exports selected resource, Metal, and diagnostic summaries.
Physical iOS runtime monitoring and real MetricKit delivery remain unverified.
Use matched Release replays for optimization comparisons. Debugger pauses distort frame windows.
Disable **Debug executable** in the scheme editor when you need a run without LLDB.
