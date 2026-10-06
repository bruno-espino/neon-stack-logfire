import json
import os
import sys
import uuid
from pathlib import Path

import logfire
import psutil
import pytest
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from xcode_observe import build_identity
from xcode_observe.build_identity import source_digest
from xcode_observe.native_observe import JSON, JSONStream, capture, latest_session, observe, read_session, summaries
from xcode_observe.telemetry import Telemetry, preserve_observation_id


def apple_update(pid: int) -> JSON:
    return {
        "PID": pid,
        "Date": "2026-10-06T02:00:00Z",
        "Layers": [
            {
                "Performance Stats": {
                    "Duration MCT Seconds": 1.0,
                    "Frame-On-Glass Interval Stats": {"Average (ms)": 16.7, "Count": 59},
                    "Presented Frame Stats": {
                        "FPS": 59.8,
                        "Frame Count": 60,
                        "On-GPU Walltime Stats": {"Average (ms)": 1.2, "Count": 60},
                    },
                    "Skipped Frame Stats": {"Frame Count": 2},
                }
            }
        ],
    }


def test_native_stream_handles_pretty_json_split_utf8_and_multiple_updates() -> None:
    stream = JSONStream()
    data = (
        json.dumps({"text": "é", **apple_update(1)}, ensure_ascii=False, indent=2) + json.dumps(apple_update(2))
    ).encode()
    values: list[JSON] = []
    for byte in data:
        values.extend(stream.feed(bytes([byte])))
    assert [value["PID"] for value in values] == [1, 2]
    assert values[0]["text"] == "é"
    result = summaries(values[0], 1)[0]
    assert result["presented_fps"] == 59.8
    assert result["frame_on_glass_mean_ms"] == 16.7
    assert result["skipped_frames"] == 2
    assert "cpu_wall_mean_ms" not in result
    assert summaries(values[0], 2) == []


def test_observer_and_capture_preserve_session_identity(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    process = psutil.Process()
    marker = {
        "pid": process.pid,
        "executable": process.exe(),
        "started_at": process.create_time() + 0.1,
        "session_id": str(uuid.uuid4()),
        "build.id": "synthetic-build",
        "build.trace_id": "a" * 32,
    }
    path = tmp_path / "session.json"
    path.write_text(json.dumps(marker))
    session, marker = read_session(path)
    marker["marker_path"] = str(path)
    path.write_text(json.dumps({**marker, "started_at": process.create_time() - 100}))
    with pytest.raises(ValueError, match="does not identify"):
        read_session(path)
    path.write_text(json.dumps(marker))
    executable = tmp_path / "metalperftrace"
    historical = apple_update(process.pid)
    historical["End Date"] = historical.pop("Date")
    historical["Layers"][0]["Total Session Stats"] = historical["Layers"][0].pop("Performance Stats")
    executable.write_text(
        f"#!{sys.executable}\nimport json,pathlib,sys,time\n"
        "if sys.argv[1]=='listen':\n"
        f" print(json.dumps({apple_update(process.pid)!r},indent=2),flush=True)\n time.sleep(0.1)\n"
        "elif sys.argv[1]=='collect':\n pathlib.Path(sys.argv[-1],'capture.atrc').write_bytes(b'native-capture')\n"
        f"else:\n print(json.dumps([{apple_update(process.pid + 1)!r}, {historical!r}]))\n"
    )
    executable.chmod(0o700)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    exporter = InMemorySpanExporter()
    client = logfire.configure(
        local=True,
        send_to_logfire=False,
        console=False,
        inspect_arguments=False,
        scrubbing=logfire.ScrubbingOptions(callback=preserve_observation_id),
        additional_span_processors=[SimpleSpanProcessor(exporter)],
    )

    telemetry = Telemetry(False, "local")
    telemetry.client = client
    output = tmp_path / "artifacts"
    assert observe(session, marker, output, 1, telemetry) == 1
    manifest_path = capture(session, marker, output, 1, telemetry)
    manifest = json.loads(manifest_path.read_text())
    assert manifest["build.id"] == "synthetic-build"
    assert manifest["session_id"] == str(session.session_id).upper()
    assert manifest["capture.started_at"] >= session.started_at
    assert len(manifest["artifacts"]["capture.atrc"]) == 64
    assert manifest["capture.measurements"][0]["gpu_wall_mean_ms"] == 1.2
    overview = json.loads(manifest_path.with_name("capture.overview.json").read_text())
    assert [item["PID"] for item in overview] == [process.pid]
    spans = exporter.get_finished_spans()
    performance = next(span for span in spans if span.name == "game.native.performance")
    attached = next(span for span in spans if span.name == "game.profile.capture")
    assert performance.attributes is not None
    assert attached.attributes is not None
    assert performance.attributes["presented_fps"] == 59.8
    assert performance.attributes["session_id"] == str(session.session_id).upper()
    assert attached.attributes["build.trace_id"] == "a" * 32
    summary = next(span for span in spans if span.name == "game.native.capture_summary")
    assert summary.attributes is not None
    assert summary.attributes["presented_fps"] == 59.8
    assert summary.attributes["capture.id"] == manifest["capture.id"]
    assert summary.attributes["recorded_at"] == historical["End Date"]
    assert (output / "native.jsonl").read_text().count("\n") == 1


def test_latest_session_uses_verified_launch_time(tmp_path: Path) -> None:
    process = psutil.Process()
    marker = {
        "pid": process.pid,
        "executable": process.exe(),
        "started_at": process.create_time() + 0.1,
        "session_id": str(uuid.uuid4()),
    }
    newest = tmp_path / "newest.json"
    newest.write_text(json.dumps({**marker, "started_at": process.create_time() + 0.2}))
    (tmp_path / "older.json").write_text(json.dumps(marker))
    (tmp_path / "invalid.json").write_text(json.dumps({**marker, "started_at": process.create_time() - 10}))
    session, selected = latest_session(tmp_path)
    assert session.started_at == process.create_time() + 0.2
    assert selected["marker_path"] == str(newest.resolve())
    newest.unlink()
    (tmp_path / "older.json").unlink()
    with pytest.raises(ValueError, match="No live development session"):
        latest_session(tmp_path)


def test_only_observation_uuids_survive_default_scrubbing() -> None:
    exporter = InMemorySpanExporter()
    client = logfire.configure(
        local=True,
        send_to_logfire=False,
        console=False,
        inspect_arguments=False,
        scrubbing=logfire.ScrubbingOptions(callback=preserve_observation_id),
        additional_span_processors=[SimpleSpanProcessor(exporter)],
    )
    identifier = str(uuid.uuid4())
    client.info("test.uuid", session_id=identifier, password="synthetic-password", auth_session=identifier)
    client.info("test.secret", session_id="synthetic-secret")
    client.force_flush()
    values = exporter.get_finished_spans()
    assert values[0].attributes is not None
    assert values[1].attributes is not None
    assert values[0].attributes["session_id"] == identifier
    assert values[0].attributes["password"] != "synthetic-password"
    assert values[0].attributes["auth_session"] != identifier
    assert values[1].attributes["session_id"] != "synthetic-secret"


def test_source_digest_distinguishes_local_edits_and_ignores_generated_output(tmp_path: Path) -> None:
    source = tmp_path / "Game.swift"
    source.write_text("let frames = 1")
    first = source_digest([tmp_path])
    hidden = tmp_path / ".build"
    hidden.mkdir()
    (hidden / "Generated.swift").write_text("generated")
    assert source_digest([tmp_path]) == first
    source.write_text("let frames = 2")
    assert source_digest([tmp_path]) != first


def test_build_phase_retains_wrapped_identity_without_credentials(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source"
    (source / "NeonStack").mkdir(parents=True)
    (source / "NeonStack/Game.swift").write_text("let frames = 1")
    package = tmp_path / "package"
    (package / "Sources").mkdir(parents=True)
    (package / "Package.swift").write_text("// package")
    output = tmp_path / "App/LogfireBuild.json"
    identifier = str(uuid.uuid4())
    monkeypatch.setenv("LOGFIRE_BUILD_ID", identifier)
    monkeypatch.setenv("LOGFIRE_BUILD_TRACE_ID", "a" * 32)
    monkeypatch.setenv("LOGFIRE_TOKEN", "synthetic-secret")
    monkeypatch.setenv("CONFIGURATION", "Release")
    monkeypatch.setattr(
        sys, "argv", ["identity", "--source", str(source), "--package", str(package), "--output", str(output)]
    )
    assert build_identity.main() == 0
    metadata = json.loads(output.read_text())
    assert metadata["build.id"] == identifier
    assert metadata["build.trace_id"] == "a" * 32
    assert metadata["build.configuration"] == "Release"
    assert "synthetic-secret" not in output.read_text()
    assert len(metadata["build.source_digest"]) == 64
