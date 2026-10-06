import json
import sys
from pathlib import Path

import logfire
import pytest
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from pydantic import ValidationError

from xcode_observe import game_profile
from xcode_observe.game_profile import PerformanceWindow, export_windows, read_windows, run_replay


def window_data() -> dict[str, str | int | float]:
    return {
        "recorded_at": "2026-10-05T21:00:00Z",
        "elapsed_seconds": 7.1,
        "window_seconds": 5.0,
        "frames": 300,
        "render_mode": "neon",
        "render_callback_fps": 60.0,
        "frame_interval_p50_ms": 16.67,
        "frame_interval_p95_ms": 18.2,
        "cpu_frame_p95_ms": 0.4,
        "gpu_samples": 0,
        "frames_over_25_ms": 2,
        "lines": 3,
        "score": 400,
        "drawable_width": 600,
        "drawable_height": 1200,
        "thermal_state": 0,
    }


def test_retains_windows_without_inventing_gpu_measurements(tmp_path: Path) -> None:
    path = tmp_path / "report.jsonl"
    data = window_data()
    path.write_text(json.dumps(data) + "\n" + json.dumps({**data, "frames": 295}) + "\n")
    windows = read_windows(path)
    assert [window.frames for window in windows] == [300, 295]
    assert all(window.gpu_command_p95_ms is None for window in windows)
    with pytest.raises(ValidationError):
        PerformanceWindow.model_validate({**data, "frame_interval_p95_ms": -1})


def test_game_process_does_not_receive_telemetry_credentials(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    app = tmp_path / "Fake.app"
    executable = app / "Contents" / "MacOS" / "Fake"
    executable.parent.mkdir(parents=True)
    executable.write_text(
        f"#!{sys.executable}\n"
        "import json,os,pathlib\n"
        'pathlib.Path(os.environ["NEON_PERF_REPORT"]).write_text(json.dumps({\n'
        ' "leaked": any(k.startswith(("LOGFIRE_", "OTEL_")) for k in os.environ),\n'
        ' "seed": os.environ["NEON_SEED"], "mode": os.environ["NEON_RENDER_MODE"],\n'
        ' "session": os.environ["NEON_SESSION_ID"], "detail": os.environ["NEON_AURORA_LAYERS"]}))\n'
    )
    executable.chmod(0o700)
    monkeypatch.setenv("LOGFIRE_TOKEN", "synthetic-write-token")
    monkeypatch.setenv("LOGFIRE_MCP_TOKEN", "synthetic-api-key")
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_HEADERS", "synthetic-secret")
    report, exit_code = run_replay(
        app, tmp_path / "artifacts", 1, 777, "aurora", False, aurora_layers=48, session_id="synthetic-session"
    )
    assert exit_code == 0
    assert json.loads(report.read_text()) == {
        "leaked": False,
        "seed": "777",
        "mode": "aurora",
        "session": "synthetic-session",
        "detail": "48",
    }


def test_export_preserves_windows_and_links_the_build(monkeypatch: pytest.MonkeyPatch) -> None:
    exporter = InMemorySpanExporter()
    client = logfire.configure(
        local=True,
        send_to_logfire=False,
        console=False,
        inspect_arguments=False,
        additional_span_processors=[SimpleSpanProcessor(exporter)],
    )

    class LocalTelemetry:
        def __init__(self, enabled: bool, host_model: str) -> None:
            self.client = client

        def flush(self) -> bool:
            return client.force_flush()

    monkeypatch.setattr(game_profile, "Telemetry", LocalTelemetry)
    window = PerformanceWindow.model_validate(window_data())
    trace_id, flushed = export_windows(
        [window, window],
        "session-1",
        777,
        "a" * 32,
        False,
        app_metadata={"build.id": "built-binary", "git.commit": "binary-commit"},
    )
    spans = exporter.get_finished_spans()
    root = next(span for span in spans if span.name == "game.session")
    samples = [span for span in spans if span.name == "game.performance.window"]
    assert trace_id and len(trace_id) == 32
    assert flushed
    assert root.attributes is not None
    assert root.context is not None
    assert root.attributes["build.trace_id"] == "a" * 32
    assert root.attributes["game.seed"] == 777
    assert root.attributes["build.id"] == "built-binary"
    assert root.attributes["git.commit"] == "binary-commit"
    assert len(samples) == 2
    for span in samples:
        assert span.parent is not None and span.attributes is not None
        assert span.parent.span_id == root.context.span_id
        assert span.attributes["frame_interval_p95_ms"] == 18.2
        assert span.attributes["build.id"] == "built-binary"


def test_aurora_quality_is_bounded_and_preserved() -> None:
    data = {**window_data(), "render_mode": "aurora", "aurora_layers": 48}
    assert PerformanceWindow.model_validate(data).aurora_layers == 48
    with pytest.raises(ValidationError):
        PerformanceWindow.model_validate({**data, "aurora_layers": 49})
