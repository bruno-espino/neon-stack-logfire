# Reproduce a SwiftUI CPU investigation

This case recreates Log Roll's former every-frame SwiftUI publication bug. The current game bounds HUD and map updates.
Both policies run the same Release binary, seed, particle count, and two-maze/loss scenario. The fault requires an explicit development scenario.

The intended claim is that bounded publication reduces main-thread CPU activity while preserving gameplay, and native CPU samples identify SwiftUI work.
Measurements may reject that claim. This case does not establish demand from other developers or measure a human's debugging time.

## Measurement plan

Build once in Release through `logfire-apple build`. Run each policy once for warmup, then alternate five runs per policy without profiling.
Use the SDK's complete five-second responsiveness windows to calculate main-thread CPU as a fraction of one core.
Weight those fractions by each window's duration. Report the median and range across runs.
Also report callback cadence, GPU command-buffer time, and total scenario duration. Renderer callbacks do not measure display presentation.
Count nonzero exit codes and verify the same score, loss, moves, turns, and simulation duration.
Retain publication counts to establish that the compared work actually ran.

Use a separate `run --profile cpu` for diagnosis. Exclude that run from performance measurements.
Report recording and decoding costs separately. Time Profiler samples running code and cannot identify a blocked resource.
Keep the normal 20-second app deadline. Cold profiler setup may make the diagnostic run incomplete.

The machine has other desktop activity. Alternate policies to limit drift and disclose the resulting variability.
No extra profiler, native Metal collection, or Simulator run belongs in the default development check.

## Run the case

Install and configure the companion through the [native workflow](native-workflow.md). Run these commands from the repository root.

```sh
logfire-apple build --scenario cpu-hud-case -- \
  -project examples/neon-stack/NeonStack.xcodeproj -scheme NeonStack \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/tmp/DerivedData-macos" CODE_SIGNING_ALLOWED=NO build
xcrun swift examples/neon-stack/tests/CPUCase.swift \
  "$PWD/tmp/DerivedData-macos/Build/Products/Release/NeonStack.app" \
  "$PWD/tmp/cpu-case-runs"
logfire-apple run \
  --app "$PWD/tmp/DerivedData-macos/Build/Products/Release/NeonStack.app" \
  --scenario examples/neon-stack/scenarios/log-roll-hud-every-frame.json \
  --profile cpu --output "$PWD/tmp/cpu-case-profile"
```

The optional case takes about two and a half minutes for twelve short app launches.
It discards the warmup pair and retains `comparison.json` with every run, publication counts, failures, medians, and ranges.
It rejects Debug builds, mismatched build identities, changed render contexts, and different gameplay outcomes.
A successful case means that the measurements are comparable. It does not impose a hardware-independent performance threshold.
`LOGFIRE_APPLE_BIN` selects a different companion executable for this script.
The default installed companion is `~/.local/bin/logfire-apple`.

For offline analysis, use `logfire-apple diagnose --report /absolute/path/to/report.json`.
This command uses retained evidence without another game launch or network export.
Open the retained `Instruments.trace` in Instruments for the full call tree.

## Verified result on October 7, 2026

Bounded publication used less CPU. The median fell from 29.0% to 8.1% of one core across five alternating runs per policy.
The ranges were 28.2% to 31.6% and 7.7% to 11.3%. All ten measured runs passed, as did the discarded warmup pair.
Each run cleared two mazes, made 60 moves and four turns, and lost after 11.741667 simulation seconds.
The same Release binary rendered 65,536 particles at 1688 by 1055 pixels on this Mac with Xcode 27 and macOS 27.
The app build ID was `5854c292-58a3-4256-b875-9762fc000209`. Its working-tree source fingerprint starts with `d590444c2ca9`.

| Measurement | Every frame | Bounded |
| --- | --- | --- |
| Full-screen publications, median and range | 704, 702 to 704 | 4, 4 to 4 |
| Map publications, median and range | 704, 702 to 704 | 273, 273 to 276 |
| Renderer callback FPS, median | 60.0003 | 59.9996 |
| App lifetime in seconds, median and range | 12.086, 12.064 to 12.310 | 12.113, 12.070 to 12.290 |
| Command duration in seconds, median and range | 12.266, 12.207 to 12.549 | 12.333, 12.265 to 12.554 |
| Worst complete-window GPU command-sum p95 in ms, median and range | 21.85, 21.19 to 25.02 | 21.00, 16.33 to 21.51 |

The callback rate remains capped near 60 Hz. This result establishes lower CPU cost, not higher FPS or faster scenario completion.
GPU variability prevents a GPU improvement claim. Command-buffer sums can exceed a callback interval without proving a missed presentation deadline.
Desktop activity varied during the run. Alternating policies reduced drift, and their CPU ranges did not overlap.

The separate warm diagnostic contained 2,040 running samples, including 1,804 ms of main-thread sampled weight.
`GraphHost.flushTransactions()` occurred in 1,201 ms, or 66.6%, of main-thread running weight.
`LogRollRenderer.render` occurred in 78 ms. These inclusive weights overlap.
The controlled publication change and counters connect that SwiftUI work to `LogRollState.refresh()`.
The sampler alone does not identify which publication is unnecessary.
Nine percent of leaf samples were unresolved, and 40.5% of sampled paths were partial. The report retains these gaps.

Recording took 10.23 seconds for a 5.72-second native interval. Offline analysis took 5.19 seconds after the app stopped.
The cold attempt returned exit 2 because tool setup and finalization exceeded the remaining recording budget.
The warm retry passed within the same app deadline. This remains a development workflow limitation.
Do not compare either profiled run with the unprofiled performance baseline.

## What the integration proves

Apple supplies the CPU recording and symbols. The SDK supplies independent CPU windows, callback windows, and gameplay evidence.
The companion verifies session identity, runs assertions, retains recordings, and decodes them after the app stops.
It sends the bounded native summaries into the same run trace as the SDK records. The Xcode build has its own trace linked by build ID.
Logfire MCP queries reproduced every measured CPU ratio from twenty ingested responsiveness windows across the ten measured sessions.
Warmups and profiler runs were excluded by exact session ID.

The investigation exposed a summary gap. Leaf functions and individual caller paths split SwiftUI work across small runtime operations.
The companion now exports `game.cpu.caller` with up to twenty inclusive functions for each main/background scope.
Its dashboard table preserves capture identity, scope, ranking, and the full running-weight denominator.
It also includes ordinary event-loop ancestors. These are expected and do not identify a root cause.
Old manifests remain readable. Offline diagnosis can recover inclusive callers from retained XML after checksum and identity validation.
The fresh validation exported forty inclusive callers in one run trace. Logfire's query returned 1,248 ms for `GraphHost.flushTransactions()`, or 66.7% of main-thread running weight.
The shared dashboard now has a validated inclusive caller table. Every previous panel remains unchanged.

The integrated command automates bookkeeping and centralizes evidence. This case does not measure a human's investigation time against Instruments.
It does not show that Logfire discovers a cause Apple tools cannot find, and it does not establish adoption by another team.
Raw recordings remain local. The next validation should use a fresh regression or another developer's game without a supplied fault label.

Sources: [Apple's current game performance workflow](https://developer.apple.com/videos/play/wwdc2026/388/),
[Logfire signal concepts](https://pydantic.dev/docs/logfire/get-started/concepts/),
and [Logfire SQL reference](https://pydantic.dev/docs/logfire/reference/sql/).
