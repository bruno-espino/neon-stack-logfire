# Drawable presentation verification

This opt-in macOS example compares two twelve-second Metal scenarios.
The normal policy presents every renderer callback. The half-rate policy presents every second callback.
Both render the same small clear workload. Other callbacks render to an offscreen texture.
The policies test measurement and diagnosis. They do not compare GPU performance.
Apple's [frame-pacing guidance](https://github.com/apple/game-porting-toolkit/blob/main/game-porting-skills/skills/presenting-metal-drawables/references/frame-pacing.md) distinguishes scheduling, submission, and display timing.
This probe observes an existing MTKView loop. The SDK does not replace the app's scheduler.

Configure this Mac with [the repository setup](../../README.md#configure-this-mac), then run:

```sh
tools/check-presentation.sh
# Retain local evidence without uploading:
tools/check-presentation.sh --no-telemetry
```

The probe uses a small floating window to reduce occlusion by other apps.
Keep it visible during each scenario.
Focus changes can flush partial windows. A run needs at least one full five-second window per policy.
Metal can return unavailable presentation timestamps. The verifier fails if confirmed cadence is absent.
It does not fill missing samples or turn unknown timestamps into dropped frames.

The script builds a small application and embeds a shared build ID and source fingerprint.
It runs both policies through the generic scenario runner with the existing twenty-second app deadline.
The runner validates app-owned readiness, completion, session identity, and telemetry acknowledgement.
It reports `presentation_cadence_gap` for full windows below 80% of callback cadence after an allowance for unknown timestamps.
At least ten valid presentation intervals are required. Intentional limits also produce this finding.
The finding suggests checking submission policy and render-loop pacing. It does not identify a GPU bottleneck.

The app pauses rendering, drains the GPU queue, closes its recorder, and flushes before completion.
The script retains reports and `verification.json` under `.xcode-observe/presentation-verification/`.
It requires separate sessions, matching build IDs, near-equal normal cadence, and half-rate cadence with the expected finding.
It stays outside `check-dev.sh`. It adds no Simulator, profiler, or longer default check.

In Logfire, select each printed session and zoom to its run interval.
Compare `render_callback_fps` with `display_presented_fps` in `game.performance.window`.
Open `development.diagnostic.finding` for `presentation_cadence_gap` and its affected interval.
SDK records share their scenario's `development.run` trace.
The probe has embedded build identity. Its bootstrap compiler invocation does not produce an `xcode.build` trace.

The experiment does not establish a performance baseline on a busy Mac.
The window-visible attribute describes the last renderer sample in each window. It does not prove continuous visibility.

The complete command passed on the development Mac. Logfire queries reproduce these full-window rates:

| Policy | Callback Hz | Confirmed presented FPS | Presentation finding |
| --- | --- | --- | --- |
| Every callback | 59.88 | 59.60 | None |
| Every second callback | 59.99 | 30.00 | `presentation_cadence_gap` |

Raw metrics include the final partial samples. Normal has 620 callbacks and 620 confirmed presentations.
Half-rate has 607 callbacks and 303 confirmed presentations.
These measurements verify the deliberate policies and complete export. They do not show a performance optimization.

## Longer dashboard audit

The optional `continuous.json` scenario runs the normal policy for 60 seconds.
`PROBE_DURATION_SECONDS` accepts a duration from 12 through 60 seconds. The default stays 12.
The probe also enables the SDK responsiveness monitor. It does not enable MetricKit.

After building the probe and reference game, run the [preview audit](../../docs/session-review.md#developer-preview-audit-on-october-9-2026).
It reuses these application bundles and retains each scenario result.
Keep the floating window visible. Focus changes can produce additional partial windows.
The longer run provides real adjacent observations. It does not fill gaps between separate sessions.
