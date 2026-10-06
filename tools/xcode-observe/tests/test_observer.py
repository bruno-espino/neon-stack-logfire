import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import logfire
import psutil
import pytest
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from xcode_observe import runner
from xcode_observe.model import BuildOptions
from xcode_observe.parser import BuildOutputParser
from xcode_observe.runner import run_build


def test_actual_xcode_timing_formats() -> None:
    parser = BuildOutputParser()
    for line in (
        "SwiftCompile 9.999 seconds",
        "Build Timing Summary",
        "",
        "SwiftCompile (2 tasks) | 0.213 seconds",
        "SwiftDriver Compilation Requirements (2 tasks) | 0.003 seconds",
        "Ld (1 task) | 0.018 seconds",
        "** BUILD SUCCEEDED **",
        "Ld 8.000 seconds",
        "Build Timing Summary",
        "SwiftCompile 0.100 seconds",
    ):
        parser.process(line)
    assert parser.timings == {
        "SwiftCompile": pytest.approx(0.313),
        "Ld": 0.018,
        "SwiftDriver Compilation Requirements": 0.003,
    }


def test_wrapped_build_passes_its_identity_to_xcode_settings(tmp_path: Path) -> None:
    settings = tmp_path / "settings.json"
    source = "import json,pathlib,sys; pathlib.Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:]))"
    report = run_build(
        [sys.executable, "-c", source, str(settings)],
        BuildOptions(artifact_dir=tmp_path / "artifacts", telemetry=False),
        {},
    )
    assert report.exit_code == 0
    arguments = json.loads(settings.read_text())
    assert f"LOGFIRE_BUILD_ID={report.build_id}" in arguments
    assert not any(argument.startswith("LOGFIRE_BUILD_TRACE_ID=") for argument in arguments)


def test_failure_status_and_retained_report(tmp_path: Path) -> None:
    report = run_build(
        [sys.executable, "-c", "print('error: synthetic failure'); raise SystemExit(65)"],
        BuildOptions(artifact_dir=tmp_path, telemetry=False),
        {},
        add_xcode_flags=False,
    )
    assert report.exit_code == 65
    assert report.errors == 1
    artifact = tmp_path / report.build_id
    assert (artifact / "build.log").read_text() == "error: synthetic failure\n"
    stored = json.loads((artifact / "report.json").read_text())
    assert stored["exit_code"] == 65
    assert stored["result_bundle"] is None
    assert (artifact / "report.json").stat().st_mode & 0o777 == 0o600


def test_caller_bundle_is_retained(tmp_path: Path) -> None:
    bundle = tmp_path / "caller.xcresult"
    bundle.mkdir()
    (bundle / "sentinel").write_text("retained")
    source = (
        "import sys; print('Build Timing Summary'); print('Ld (1 task) | 0.010 seconds'); "
        "print('bundle=' + sys.argv[sys.argv.index('-resultBundlePath') + 1])"
    )
    report = run_build(
        [sys.executable, "-c", source, "-resultBundlePath", str(bundle)],
        BuildOptions(artifact_dir=tmp_path / "artifacts", telemetry=False),
        {},
        add_xcode_flags=False,
    )
    assert report.result_bundle == bundle
    assert (bundle / "sentinel").read_text() == "retained"
    assert report.timings == {"Ld": 0.01}
    assert "bundle=" + str(bundle) in (tmp_path / "artifacts" / report.build_id / "build.log").read_text()


def test_closed_output_consumer_does_not_abort_build(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    marker = tmp_path / "finished"

    class ClosedStream:
        def write(self, data: bytes) -> int:
            raise BrokenPipeError("The consumer closed its pipe.")

        def flush(self) -> None:
            pass

    monkeypatch.setattr(runner.sys, "stdout", SimpleNamespace(buffer=ClosedStream()))
    source = "import pathlib,sys; print('building',flush=True); pathlib.Path(sys.argv[1]).write_text('done')"
    report = run_build(
        [sys.executable, "-c", source, str(marker)],
        BuildOptions(artifact_dir=tmp_path, telemetry=False),
        {},
        add_xcode_flags=False,
    )
    assert report.exit_code == 0
    assert marker.read_text() == "done"


def test_telemetry_failure_preserves_success(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def unavailable(*args: object) -> None:
        raise RuntimeError("Telemetry is unavailable.")

    monkeypatch.setattr(runner.Telemetry, "complete", unavailable)
    report = run_build(
        [sys.executable, "-c", "pass"],
        BuildOptions(artifact_dir=tmp_path, telemetry=False),
        {},
        add_xcode_flags=False,
    )
    assert report.exit_code == 0
    assert report.observation_errors == ["Build telemetry failed. The build exit code is unchanged."]


def test_short_build_keeps_every_sample(tmp_path: Path) -> None:
    report = run_build(
        [sys.executable, "-c", "import time; time.sleep(0.65)"],
        BuildOptions(artifact_dir=tmp_path, telemetry=False, sample_interval=0.1),
        {},
        add_xcode_flags=False,
    )
    stored = json.loads((tmp_path / report.build_id / "report.json").read_text())
    assert len(report.samples) >= 4
    assert len(stored["samples"]) == len(report.samples)
    assert all(0 <= sample.cpu_utilization <= 1 for sample in report.samples)
    assert all(sample.elapsed_seconds >= 0.1 for sample in report.samples)


def test_sample_export_failure_keeps_local_history(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def unavailable(*args: object) -> None:
        raise RuntimeError("Sample export is unavailable.")

    monkeypatch.setattr(runner.Telemetry, "sample", unavailable)
    report = run_build(
        [sys.executable, "-c", "import time; time.sleep(0.65)"],
        BuildOptions(artifact_dir=tmp_path, telemetry=False, sample_interval=0.1),
        {},
        add_xcode_flags=False,
    )
    assert report.exit_code == 0
    assert len(report.samples) >= 4
    assert report.observation_errors == ["Host sample export failed. Local sampling continues."]


def test_trace_contains_every_sample_without_raw_command(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    exporter = InMemorySpanExporter()
    original = runner.Telemetry

    class LocalTelemetry(original):
        def __init__(self, enabled: bool, host_model: str) -> None:
            super().__init__(False, host_model)
            self.client = logfire.configure(
                local=True,
                send_to_logfire=False,
                console=False,
                inspect_arguments=False,
                additional_span_processors=[SimpleSpanProcessor(exporter)],
            )
            self.duration = self.client.metric_histogram("xcode.build.duration")
            self.builds = self.client.metric_counter("xcode.build.total")
            self.cpu = self.client.metric_gauge("system.cpu.simple_utilization")
            self.memory = self.client.metric_gauge("system.memory.utilization")
            self.disk_free = self.client.metric_gauge("system.filesystem.usage")

    monkeypatch.setattr(runner, "Telemetry", LocalTelemetry)
    report = run_build(
        [sys.executable, "-c", "import time; time.sleep(0.4)", "CUSTOM_SETTING=private-value"],
        BuildOptions(artifact_dir=tmp_path, sample_interval=0.1),
        {"build.scheme": "SyntheticGame"},
        add_xcode_flags=False,
    )
    spans = exporter.get_finished_spans()
    roots = [span for span in spans if span.name == "xcode.build"]
    samples = [span for span in spans if span.name == "xcode.host.sample"]
    assert len(roots) == 1
    assert len(samples) == len(report.samples)
    assert report.trace_id is not None
    assert roots[0].attributes is not None and roots[0].context is not None
    assert roots[0].attributes["build.success"] is True
    assert "private-value" not in str([span.attributes for span in spans])
    assert all(span.parent is not None and span.parent.span_id == roots[0].context.span_id for span in samples)


def test_sigterm_kills_process_group_and_returns_143(tmp_path: Path) -> None:
    ready = tmp_path / "ready"
    child_source = (
        "import os,pathlib,signal,subprocess,sys,time; "
        "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
        "grandchild=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
        "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())+','+str(grandchild.pid)); time.sleep(60)"
    )
    source = (
        "import pathlib,sys\n"
        "from xcode_observe.model import BuildOptions\n"
        "from xcode_observe.runner import run_build\n"
        f"child = {child_source!r}\n"
        'report = run_build([sys.executable,"-c",child,sys.argv[1]],'
        "BuildOptions(artifact_dir=pathlib.Path(sys.argv[2]),telemetry=False),{},add_xcode_flags=False)\n"
        "raise SystemExit(report.exit_code)\n"
    )
    process = subprocess.Popen([sys.executable, "-c", source, str(ready), str(tmp_path / "artifacts")])
    child_pids: list[int] = []
    try:
        deadline = time.monotonic() + 10
        while not ready.exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                pytest.fail("The test build did not start.")
            time.sleep(0.05)
        child_pids = [int(pid) for pid in ready.read_text().split(",")]
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=10) == 143
        for pid in child_pids:
            if psutil.pid_exists(pid):
                assert psutil.Process(pid).status() == psutil.STATUS_ZOMBIE
        reports = list((tmp_path / "artifacts").glob("*/report.json"))
        assert len(reports) == 1
        assert json.loads(reports[0].read_text())["exit_code"] == 143
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        for pid in child_pids:
            if psutil.pid_exists(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
