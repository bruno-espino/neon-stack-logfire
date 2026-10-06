"""Run a bounded, fixed-seed game replay and export window summaries.

The game writes a local JSONL report without credentials. This separate client
exports validated five-second windows after the replay. It retains the report
and an optional Instruments trace. Each invocation creates a fresh session.
"""

import argparse
import os
import platform
import signal
import subprocess
import time
import uuid
from pathlib import Path
from typing import Literal

from opentelemetry import trace
from pydantic import BaseModel, Field, TypeAdapter
from requests.exceptions import RequestException

from xcode_observe.build_identity import load_host_credentials
from xcode_observe.model import BuildOptions, build_metadata
from xcode_observe.runner import Cancellation, cancellation_handlers, signal_group
from xcode_observe.telemetry import Telemetry


class PerformanceWindow(BaseModel):
    recorded_at: str
    elapsed_seconds: float = Field(gt=0)
    window_seconds: float = Field(gt=0)
    frames: int = Field(gt=0)
    render_mode: Literal["classic", "neon", "aurora"]
    aurora_layers: int = Field(default=0, ge=0, le=48)
    workload: Literal["onscreen", "offscreen"] = "onscreen"
    render_callback_fps: float = Field(gt=0)
    frame_interval_p50_ms: float = Field(gt=0)
    frame_interval_p95_ms: float = Field(gt=0)
    cpu_frame_p95_ms: float = Field(ge=0)
    gpu_command_p95_ms: float | None = Field(default=None, ge=0)
    gpu_samples: int = Field(ge=0)
    frames_over_25_ms: int = Field(ge=0)
    lines: int = Field(ge=0)
    score: int = Field(ge=0)
    drawable_width: int = Field(gt=0)
    drawable_height: int = Field(gt=0)
    thermal_state: int = Field(ge=0, le=3)


def read_windows(path: Path) -> list[PerformanceWindow]:
    return [PerformanceWindow.model_validate_json(line) for line in path.read_text().splitlines() if line.strip()]


def run_replay(
    app: Path,
    output: Path,
    seconds: float,
    seed: int,
    mode: str,
    instruments: bool,
    offscreen: bool = False,
    aurora_layers: int = 24,
    session_id: str | None = None,
) -> tuple[Path, int]:
    output.mkdir(parents=True, mode=0o700)
    report = output / "performance.jsonl"
    environment = {key: value for key, value in os.environ.items() if not key.startswith(("LOGFIRE_", "OTEL_"))}
    environment.update(
        {
            "NEON_PERF_REPORT": str(report),
            "NEON_BENCHMARK": "1",
            "NEON_SEED": str(seed),
            "NEON_RENDER_MODE": mode,
            "NEON_BENCHMARK_SECONDS": str(seconds if offscreen else seconds + 2),
            "NEON_OFFSCREEN": "1" if offscreen else "0",
            "NEON_AURORA_LAYERS": str(aurora_layers),
            "NEON_SESSION_ID": session_id or str(uuid.uuid4()),
        }
    )
    if instruments:
        command = [
            "xcrun",
            "xctrace",
            "record",
            "--template",
            "Game Performance",
            "--time-limit",
            f"{round(seconds * 1000)}ms",
            "--window",
            f"{round(seconds * 1000)}ms",
            "--output",
            str(output / "GamePerformance.trace"),
            "--launch",
            "--",
            str(app),
        ]
        # xctrace requires explicit launch environment arguments for the target.
        for key in (
            "NEON_PERF_REPORT",
            "NEON_BENCHMARK",
            "NEON_SEED",
            "NEON_RENDER_MODE",
            "NEON_BENCHMARK_SECONDS",
            "NEON_OFFSCREEN",
            "NEON_AURORA_LAYERS",
            "NEON_SESSION_ID",
        ):
            command[command.index("--launch") : command.index("--launch")] = ["--env", f"{key}={environment[key]}"]
    else:
        command = [str(app / "Contents" / "MacOS" / app.stem)]
    with (output / "console.log").open("wb") as console:
        cancellation = Cancellation()
        with cancellation_handlers(cancellation):
            process = subprocess.Popen(
                command, env=environment, stdout=console, stderr=subprocess.STDOUT, start_new_session=True
            )
            deadline = time.monotonic() + seconds + (60 if instruments else (5 if offscreen else 0))
            stopping: float | None = None
            timed_out = False
            try:
                while process.poll() is None:
                    now = time.monotonic()
                    if stopping is None and (cancellation.signum is not None or now >= deadline):
                        timed_out = cancellation.signum is None
                        signal_group(process, cancellation.signum or signal.SIGTERM)
                        stopping = now + 3
                    if stopping is not None and now >= stopping:
                        signal_group(process, signal.SIGKILL)
                    time.sleep(0.05)
                code = process.wait()
                if cancellation.signum is not None:
                    code = 128 + cancellation.signum
                elif timed_out:
                    code = 1 if instruments else 0
            finally:
                if process.poll() is None:
                    signal_group(process, signal.SIGKILL)
                process.wait()
    return report, code


def export_windows(
    windows: list[PerformanceWindow],
    session_id: str,
    seed: int,
    build_trace: str | None,
    profiled: bool,
    app_metadata: dict[str, str] | None = None,
) -> tuple[str | None, bool]:
    metadata = build_metadata([], BuildOptions())
    metadata.update(app_metadata or {})
    telemetry = Telemetry(True, str(metadata.get("host.model", "unknown")))
    client = telemetry.client
    if client is None:
        return None, False
    with client.span("game.session") as span:
        span.set_attributes(
            {
                **metadata,
                "game.session_id": session_id,
                "game.name": "NeonStack",
                "game.seed": seed,
                "game.instrumented": profiled,
                "game.render_mode": windows[0].render_mode,
                "game.workload": windows[0].workload,
                "game.windows": len(windows),
                "build.trace_id": build_trace,
            }
        )
        for window in windows:
            attributes = window.model_dump() | (app_metadata or {})
            attributes["session_id"] = session_id
            client.log("info", "game.performance.window", attributes=attributes)
        trace_id = format(trace.get_current_span().get_span_context().trace_id, "032x")
    return trace_id, telemetry.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=20)
    parser.add_argument("--seed", type=int, default=777)
    parser.add_argument("--render-mode", choices=("neon", "classic", "aurora"), default="neon")
    parser.add_argument("--aurora-layers", type=int, default=24, help="Aurora detail from 1 to 48 layers.")
    parser.add_argument("--artifact-dir", type=Path, default=Path(".xcode-observe/runtime"))
    parser.add_argument("--build-trace-id")
    parser.add_argument("--instruments", action="store_true")
    parser.add_argument(
        "--offscreen", action="store_true", help="Render a paced Metal texture workload without a window."
    )
    args = parser.parse_args()
    if platform.system() != "Darwin" or not args.app.is_dir():
        parser.error("--app must name a built macOS application on this Mac.")
    if not 12 <= args.seconds <= 300:
        parser.error("--seconds must be between 12 and 300.")
    if not 0 <= args.seed <= 2**64 - 1:
        parser.error("--seed must fit an unsigned 64-bit integer.")
    if not 1 <= args.aurora_layers <= 48:
        parser.error("--aurora-layers must be between 1 and 48.")
    session_id = str(uuid.uuid4()).upper()
    output = args.artifact_dir.resolve() / session_id
    report, code = run_replay(
        args.app.resolve(),
        output,
        args.seconds,
        args.seed,
        args.render_mode,
        args.instruments,
        args.offscreen,
        args.aurora_layers,
        session_id,
    )
    if code or not report.is_file():
        print(f"Replay failed. Inspect {output / 'console.log'}.")
        return code or 1
    windows = read_windows(report)
    if not windows:
        print(f"No complete performance window. Inspect {report}.")
        return 1
    print(f"Retained {len(windows)} windows: {report}")
    for window in windows:
        rate_label = "paced loop Hz" if window.workload == "offscreen" else "callback FPS"
        print(
            f"{window.render_mode}: {window.render_callback_fps:.1f} {rate_label}, "
            f"p95 interval {window.frame_interval_p95_ms:.2f}ms, GPU {window.gpu_command_p95_ms}ms"
        )
    try:
        load_host_credentials()
        identity = args.app / "Contents/Resources/LogfireBuild.json"
        app_metadata: dict[str, str] = (
            TypeAdapter(dict[str, str]).validate_json(identity.read_text()) if identity.is_file() else {}
        )
        trace_id, flushed = export_windows(
            windows,
            session_id,
            args.seed,
            args.build_trace_id or app_metadata.get("build.trace_id"),
            args.instruments,
            app_metadata=app_metadata,
        )
        print(f"Logfire trace: {trace_id}; flushed: {flushed}")
    except OSError, ValueError, RuntimeError, RequestException:
        print("Telemetry export failed. The local performance report remains available.")
    return 0
