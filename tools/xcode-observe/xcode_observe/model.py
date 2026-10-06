"""Define build metadata and local reports."""

import os
import platform
import subprocess
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field

Attribute = str | int | float | bool


class BuildOptions(BaseModel):
    artifact_dir: Path = Path(".xcode-observe")
    sample_interval: float = Field(default=1.0, ge=0.1)
    cache_state: Literal["unknown", "cold", "warm"] = "unknown"
    scenario: str = "manual"
    run_id: str | None = None
    telemetry: bool = True


class HostSample(BaseModel):
    elapsed_seconds: float
    cpu_utilization: float
    memory_utilization: float
    swap_used_bytes: int
    disk_free_bytes: int
    disk_read_bytes: int
    disk_write_bytes: int


class BuildReport(BaseModel):
    build_id: str
    exit_code: int
    duration_seconds: float
    metadata: dict[str, Attribute]
    timings: dict[str, float] = Field(default_factory=dict)
    warnings: int = 0
    errors: int = 0
    samples: list[HostSample] = Field(default_factory=list[HostSample])
    result_bundle: Path | None = None
    trace_id: str | None = None
    telemetry_flushed: bool = False
    observation_errors: list[str] = Field(default_factory=list)


def command_output(command: list[str]) -> str | None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=False)
    except OSError, subprocess.TimeoutExpired:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def argument_value(arguments: list[str], flag: str) -> str | None:
    for index, argument in enumerate(arguments[:-1]):
        if argument == flag:
            return arguments[index + 1]
    return None


def build_metadata(arguments: list[str], options: BuildOptions) -> dict[str, Attribute]:
    metadata: dict[str, Attribute] = {
        "build.cache_state": options.cache_state,
        "build.scenario": options.scenario,
        "host.arch": platform.machine(),
        "host.macos_version": platform.mac_ver()[0],
    }
    if options.run_id is not None:
        metadata["walkthrough.run_id"] = options.run_id
    flags = {
        "-scheme": "build.scheme",
        "-configuration": "build.configuration",
        "-sdk": "build.sdk",
        "-destination": "build.destination",
        "-project": "build.project",
        "-workspace": "build.workspace",
    }
    for flag, name in flags.items():
        value = argument_value(arguments, flag)
        if value is not None:
            metadata[name] = Path(value).name if flag in {"-project", "-workspace"} else value
    actions = {"build", "test", "archive", "clean", "analyze", "build-for-testing", "test-without-building"}
    action_values = [arg for arg in arguments if arg in actions]
    metadata["build.actions"] = ",".join(action_values) or "build"
    for name, command in {
        "host.model": ["sysctl", "-n", "hw.model"],
        "git.commit": ["git", "rev-parse", "HEAD"],
        "git.branch": ["git", "branch", "--show-current"],
    }.items():
        value = command_output(command)
        if value:
            metadata[name] = value
    dirty = command_output(["git", "status", "--porcelain"])
    if dirty is not None:
        metadata["git.dirty"] = bool(dirty)
    xcode = command_output(["xcodebuild", "-version"])
    if xcode:
        for line in xcode.splitlines():
            if line.startswith("Xcode "):
                metadata["xcode.version"] = line.removeprefix("Xcode ")
            elif line.startswith("Build version "):
                metadata["xcode.build_version"] = line.removeprefix("Build version ")
    for variable, name in {
        "GITHUB_RUN_ID": "ci.run_id",
        "GITHUB_JOB": "ci.job",
        "CI_BUILD_NUMBER": "ci.build_number",
    }.items():
        if value := os.environ.get(variable):
            metadata[name] = value
    return metadata
