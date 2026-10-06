"""Build a Metal game under five observable Xcode scenarios.

Inputs are a run ID and Logfire environment variables. Xcode and the observer's
standalone virtual environment must exist. The script creates owned build
artifacts and emits telemetry. The contention scenario starts at most four CPU
workers for at most 30 seconds and reaps them after its build. A completed run ID
reuses its manifest. Success means four successful builds, one expected failed
build, retained reports, and a successful telemetry flush when a token is set.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENARIO = Path(__file__).resolve().parent
OBSERVER = ROOT / "tools" / "xcode-observe" / ".venv" / "bin" / "xcode-observe"


class ScenarioError(RuntimeError):
    """A build scenario did not meet its expected result."""


def run_suffix(value: str) -> str:
    prefix = re.sub(r"[^a-zA-Z0-9_-]", "-", value).strip("-")[:40] or "run"
    digest = hashlib.sha256(value.encode()).hexdigest()[:16]
    return f"{prefix}-{digest}"


def run_scenarios(run_id: str) -> None:
    if platform.system() != "Darwin" or shutil.which("xcodebuild") is None:
        raise ScenarioError("This example requires macOS and a selected Xcode installation.")
    if not OBSERVER.is_file():
        raise ScenarioError("Install the observer with uv sync --project tools/xcode-observe first.")
    target = (
        "/".join(
            os.environ.get(key, "")
            for key in (
                "LOGFIRE_BASE_URL",
                "LOGFIRE_ORGANIZATION",
                "LOGFIRE_PROJECT",
            )
        )
        + "/NeonStack-v1"
        + ("/telemetry" if os.environ.get("LOGFIRE_TOKEN") else "/local")
    )
    owned = SCENARIO / ".xcode-observe" / run_suffix(run_id + target)
    owned.mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest = owned / "manifest.json"
    if manifest.is_file():
        print(f"Reusing the completed run. Reports: {manifest}")
        return
    scenarios = (
        ("cold-macos", "cold", "macos", False, 0),
        ("warm-macos", "warm", "macos", False, 0),
        ("cold-ios", "cold", "ios", False, 0),
        ("cpu-contention", "cold", "macos", True, 0),
        ("failed-scheme", "unknown", "macos", False, 65),
    )
    reports: dict[str, str] = {}
    for name, cache, destination, contention, expected in scenarios:
        artifacts = owned / name
        done = artifacts / "completed.json"
        if done.is_file():
            reports[name] = done.read_text().strip()
            continue
        derived = owned / ("DerivedData-ios" if destination == "ios" else "DerivedData-macos")
        arguments = [
            "-project",
            str(SCENARIO / "NeonStack.xcodeproj"),
            "-scheme",
            "MissingScheme" if expected else "NeonStack",
            "-configuration",
            "Debug",
            "-derivedDataPath",
            str(derived),
        ]
        if destination == "ios":
            arguments += ["-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator"]
        else:
            arguments += ["-destination", f"platform=macOS,arch={platform.machine()}"]
        arguments += ["clean", "build"] if cache == "cold" else ["build"]
        command = [
            str(OBSERVER),
            "--artifact-dir",
            str(artifacts),
            "--sample-interval",
            "0.25",
            "--cache-state",
            cache,
            "--scenario",
            name,
            "--run-id",
            run_id,
            "--",
            *arguments,
        ]
        workers: list[subprocess.Popen[bytes]] = []
        print(f"Running {name}", flush=True)
        try:
            if contention:
                source = "import time\nend=time.monotonic()+30\nwhile time.monotonic()<end: sum(range(10000))"
                for _ in range(min(4, os.cpu_count() or 1)):
                    workers.append(subprocess.Popen([sys.executable, "-c", source]))
            result = subprocess.run(command, check=False)
        finally:
            for worker in workers:
                if worker.poll() is None:
                    worker.terminate()
            for worker in workers:
                worker.wait()
        if result.returncode != expected:
            raise ScenarioError(f"{name} returned {result.returncode}; expected {expected}. See {artifacts}.")
        candidates = sorted(artifacts.glob("*/report.json"), key=lambda path: path.stat().st_mtime)
        if not candidates:
            raise ScenarioError(f"{name} did not retain a report in {artifacts}.")
        report_path = candidates[-1]
        report = json.loads(report_path.read_text())
        if os.environ.get("LOGFIRE_TOKEN") and not report["telemetry_flushed"]:
            raise ScenarioError(f"{name} did not flush telemetry. See {report_path}.")
        reports[name] = str(report_path)
        done.write_text(str(report_path) + "\n")
    manifest.write_text(json.dumps(reports, indent=2) + "\n")
    print(f"Five scenarios completed. Reports: {manifest}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", default=datetime.now(UTC).strftime("demo-%Y%m%d-%H%M%S"))
    args = parser.parse_args()
    try:
        run_scenarios(args.run_id)
    except ScenarioError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
