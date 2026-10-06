"""Join native Metal measurements and local captures to a verified app session."""

import argparse
import codecs
import hashlib
import json
import os
import platform
import selectors
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, BinaryIO, cast

import psutil
from pydantic import BaseModel, Field, TypeAdapter
from requests.exceptions import RequestException

from xcode_observe.build_identity import load_host_credentials
from xcode_observe.model import command_output
from xcode_observe.runner import Cancellation, cancellation_handlers, signal_group
from xcode_observe.telemetry import Telemetry

JSON = dict[str, Any]


class Session(BaseModel):
    session_id: uuid.UUID
    pid: int = Field(gt=0)
    executable: Path
    started_at: float

    def attributes(self, marker: JSON) -> JSON:
        return {
            key: marker[key]
            for key in (
                "build.id",
                "build.trace_id",
                "build.configuration",
                "build.sdk",
                "build.source_digest",
                "git.commit",
                "xcode.version",
            )
            if key in marker
        } | {"session_id": str(self.session_id).upper(), "process.pid": self.pid}


def read_session(path: Path) -> tuple[Session, JSON]:
    marker = json.loads(path.read_text())
    session = Session.model_validate(marker)
    process = psutil.Process(session.pid)
    if (
        Path(process.exe()).resolve() != session.executable.resolve()
        or not 0 <= session.started_at - process.create_time() < 60
    ):
        raise ValueError("The session marker does not identify this running process")
    metadata_path = session.executable.parents[2] / "Contents/Resources/LogfireBuild.json"
    if metadata_path.is_file() and json.loads(metadata_path.read_text()).get("build.id") != marker.get("build.id"):
        raise ValueError("The app on disk was rebuilt after this session started")
    return session, marker


def latest_session(directory: Path) -> tuple[Session, JSON]:
    live: list[tuple[Session, JSON]] = []
    for path in directory.glob("*.json"):
        try:
            session, marker = read_session(path)
        except OSError, ValueError, psutil.Error:
            continue
        marker["marker_path"] = str(path.resolve())
        live.append((session, marker))
    if not live:
        raise ValueError("No live development session in the selected directory")
    return max(live, key=lambda item: (item[0].started_at, item[0].pid))


class JSONStream:
    """Apple emits indented JSON objects as well as single-line JSON updates."""

    def __init__(self) -> None:
        self.buffer = ""
        self.decoder = json.JSONDecoder()
        self.utf8 = codecs.getincrementaldecoder("utf-8")()

    def feed(self, data: bytes) -> list[JSON]:
        self.buffer += self.utf8.decode(data)
        values: list[JSON] = []
        while self.buffer.strip():
            self.buffer = self.buffer.lstrip()
            try:
                value, end = self.decoder.raw_decode(self.buffer)
            except json.JSONDecodeError:
                if len(self.buffer) > 2_000_000:
                    raise ValueError("Native JSON update exceeds the input limit") from None
                break
            if not isinstance(value, dict):
                raise ValueError("Native updates must be JSON objects")
            values.append(cast(JSON, value))
            self.buffer = self.buffer[end:]
        return values


def measured_mean(statistics: JSON) -> float | None:
    count = statistics.get("Count", 0)
    mean = statistics.get("Average (ms)")
    if isinstance(count, (int, float)) and count > 0 and isinstance(mean, (int, float)):
        return float(mean)
    return None


def summaries(update: JSON, pid: int) -> list[JSON]:
    if update.get("PID") != pid:
        return []
    values: list[JSON] = []
    for index, layer in enumerate(update.get("Layers", [])):
        stats = layer.get("Performance Stats", layer.get("Total Session Stats", {}))
        presented = stats.get("Presented Frame Stats", {})
        skipped = stats.get("Skipped Frame Stats", {})
        item = {
            "recorded_at": update.get("Date", update.get("End Date")),
            "layer_index": index,
            "measurement.source": "apple.metalperftrace",
        }
        states = {
            key: value for key, value in update.get("States", {}).items() if key.startswith("dev.example.NeonStack.")
        }
        if states:
            item["game.native.states"] = states
        fields = {
            "presented_fps": presented.get("FPS"),
            "presented_frames": presented.get("Frame Count"),
            "skipped_frames": skipped.get("Frame Count"),
            "window_seconds": stats.get("Duration MCT Seconds"),
            "frame_on_glass_mean_ms": measured_mean(stats.get("Frame-On-Glass Interval Stats", {})),
            "gpu_wall_mean_ms": measured_mean(presented.get("On-GPU Walltime Stats", {})),
            "cpu_wall_mean_ms": measured_mean(presented.get("End-to-end Walltime Stats (CPU)", {})),
            "drawable_wait_mean_ms": measured_mean(presented.get("Next Drawable Wait Walltime Stats", {})),
            "drawable_width": layer.get("Configuration", {}).get("Width (pixels)"),
            "drawable_height": layer.get("Configuration", {}).get("Height (pixels)"),
        }
        item.update({key: value for key, value in fields.items() if isinstance(value, (int, float))})
        values.append(item)
    return values


def observe(session: Session, marker: JSON, output: Path, seconds: float, telemetry: Telemetry) -> int:
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    (output / "session.json").write_text(json.dumps(marker, indent=2) + "\n")
    cancellation = Cancellation()
    stream = JSONStream()
    count = 0
    with (output / "native.jsonl").open("w") as raw, (output / "native.stderr").open("wb") as errors:
        process = subprocess.Popen(
            ["metalperftrace", "listen", "--pid", str(session.pid), "--json", "--interval", "1"],
            stdout=subprocess.PIPE,
            stderr=errors,
            start_new_session=True,
        )
        try:
            with selectors.DefaultSelector() as selector, cancellation_handlers(cancellation):
                selector.register(cast(BinaryIO, process.stdout), selectors.EVENT_READ)
                deadline = time.monotonic() + seconds
                while process.poll() is None and time.monotonic() < deadline and cancellation.signum is None:
                    try:
                        read_session(Path(marker["marker_path"]))
                    except OSError, ValueError, psutil.Error:
                        break
                    for key, _ in selector.select(timeout=0.5):
                        data = os.read(key.fd, 65536)
                        if not data:
                            continue
                        for update in stream.feed(data):
                            if update.get("PID") != session.pid:
                                continue
                            raw.write(json.dumps(update) + "\n")
                            raw.flush()
                            for summary in summaries(update, session.pid):
                                if telemetry.client is not None:
                                    telemetry.client.info(
                                        "game.native.performance", **session.attributes(marker), **summary
                                    )
                                count += 1
        finally:
            signal_group(process, signal.SIGINT)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                signal_group(process, signal.SIGKILL)
                process.wait()
            if process.stdout is not None:
                process.stdout.close()
    telemetry.flush()
    if count == 0:
        raise ValueError(f"Apple emitted no measurements. Inspect {output / 'native.stderr'}")
    print(f"Retained {count} native layer measurements in {output}")
    return count


def capture(session: Session, marker: JSON, output: Path, seconds: float, telemetry: Telemetry) -> Path:
    capture_id = str(uuid.uuid4())
    folder = output / "captures" / capture_id
    folder.mkdir(parents=True, mode=0o700)
    ended = time.time()
    started = max(session.started_at, ended - seconds)
    result = subprocess.run(
        ["metalperftrace", "collect", "--start", f"@{started}", "--end", f"@{ended}", "--json", str(folder)],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    (folder / "collect.log").write_text(result.stdout + result.stderr)
    traces = sorted(folder.glob("*.atrc"))
    if result.returncode or not traces:
        raise ValueError(f"Native capture failed. Inspect {folder / 'collect.log'}")
    measurements: list[JSON] = []
    for native_trace in traces:
        overview = subprocess.run(
            [
                "metalperftrace",
                "overview",
                "--json",
                "--include-state-transitions",
                "--predicate",
                f"pid == {session.pid}",
                str(native_trace),
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if overview.returncode:
            raise ValueError("Native capture overview failed")
        processes = TypeAdapter(list[JSON]).validate_json(overview.stdout)
        selected = [process for process in processes if process.get("PID") == session.pid]
        native_trace.with_suffix(".overview.json").write_text(json.dumps(selected, indent=2) + "\n")
        for process in selected:
            measurements.extend(summaries(process, session.pid))
    if "marker_path" in marker:
        read_session(Path(marker["marker_path"]))
    digest = hashlib.sha256(session.executable.read_bytes()).hexdigest()
    app = session.executable.parents[2]
    dsym = app.with_name(app.name + ".dSYM")
    if dsym.is_dir():
        shutil.copytree(dsym, folder / dsym.name)
    artifacts: dict[str, str] = {}
    for artifact in folder.rglob("*"):
        if artifact.is_file():
            artifacts[str(artifact.relative_to(folder))] = hashlib.sha256(artifact.read_bytes()).hexdigest()
    manifest: JSON = {
        **session.attributes(marker),
        "capture.id": capture_id,
        "capture.started_at": started,
        "capture.ended_at": ended,
        "capture.tool": "apple.metalperftrace",
        "capture.storage": "local",
        "capture.kind": "native-lookback",
        "capture.macos_version": platform.mac_ver()[0],
        "capture.path": str(folder),
        "binary.sha256": digest,
        "capture.measurements": measurements,
        "artifacts": artifacts,
    }
    manifest_path = folder / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    if telemetry.client is not None:
        telemetry.client.info("game.profile.capture", **manifest)
        for measurement in measurements:
            attributes = (
                session.attributes(marker)
                | measurement
                | {
                    "capture.id": capture_id,
                    "capture.started_at": started,
                    "capture.ended_at": ended,
                }
            )
            telemetry.client.log("info", "game.native.capture_summary", attributes=attributes)
        telemetry.flush()
    print(f"Capture attached to session {session.session_id}: {manifest_path}")
    return manifest_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["watch", "attach", "capture"])
    parser.add_argument("--sessions", type=Path, required=True)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--latest", action="store_true", help="Select the newest verified live session.")
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--artifact-dir", type=Path, default=Path(".xcode-observe/native"))
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--no-telemetry", action="store_true")
    args = parser.parse_args()
    if not shutil.which("metalperftrace"):
        parser.error("Native monitoring requires macOS 27 with metalperftrace")
    if not 1 <= args.seconds <= 3600:
        parser.error("--seconds must be between 1 and 3600")
    if args.latest and (args.pid is not None or args.action == "watch"):
        parser.error("--latest is for attach or capture and cannot be combined with --pid")
    if args.action != "watch" and args.pid is None and not args.latest:
        parser.error("Supply --pid or --latest for attach and capture")
    args.artifact_dir = args.artifact_dir.resolve()
    if args.background:
        args.artifact_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (args.artifact_dir / "watch.log").open("ab") as log:
            subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "xcode_observe.native_observe",
                    *[arg for arg in sys.argv[1:] if arg != "--background"],
                ],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        return 0
    since = time.time() - 1
    deadline = time.monotonic() + 60
    while True:
        if args.latest:
            try:
                selected = latest_session(args.sessions)
            except ValueError as error:
                parser.error(str(error))
            break
        paths = (
            [args.sessions / f"{args.pid}.json"]
            if args.pid
            else sorted(args.sessions.glob("*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
        )
        selected = None
        for path in paths:
            try:
                session, marker = read_session(path)
                if args.action != "watch" or session.started_at >= since:
                    marker["marker_path"] = str(path.resolve())
                    selected = session, marker
                    break
            except OSError, ValueError, psutil.Error:
                continue
        if selected is not None:
            break
        if args.action != "watch" or time.monotonic() >= deadline:
            parser.error("No matching live development session")
        time.sleep(0.2)
    session, marker = selected
    output = args.artifact_dir / str(session.session_id).upper()
    load_host_credentials()
    try:
        telemetry = Telemetry(not args.no_telemetry, command_output(["sysctl", "-n", "hw.model"]) or "unknown")
    except OSError, ValueError, RuntimeError, RequestException:
        print("Telemetry unavailable. Native measurements remain local.")
        telemetry = Telemetry(False, "local")
    if args.action == "capture":
        capture(session, marker, output, args.seconds, telemetry)
    else:
        observe(session, marker, output, args.seconds, telemetry)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
