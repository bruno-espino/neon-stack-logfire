"""Run a build, retain its artifacts, and contain observation failures.

The runner forwards cancellation to the process group and reaps the child.
Host samples describe the whole machine. They do not establish build causality.
"""

import codecs
import os
import selectors
import signal
import subprocess
import sys
import time
import uuid
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from types import FrameType
from typing import BinaryIO

import psutil
from opentelemetry import trace
from pydantic import BaseModel, ConfigDict
from requests.exceptions import RequestException

from xcode_observe.model import Attribute, BuildOptions, BuildReport, HostSample, argument_value
from xcode_observe.parser import BuildOutputParser
from xcode_observe.telemetry import Telemetry


class BuildResults(BaseModel):
    model_config = ConfigDict(extra="ignore")
    warningCount: int | None = None
    errorCount: int | None = None


class Cancellation:
    def __init__(self) -> None:
        self.signum: int | None = None

    def handle(self, signum: int, frame: FrameType | None) -> None:
        self.signum = signum


@contextmanager
def cancellation_handlers(cancellation: Cancellation) -> Generator[None]:
    previous = {sig: signal.signal(sig, cancellation.handle) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def signal_group(process: subprocess.Popen[bytes], signum: int) -> None:
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def host_sample(elapsed: float, disk_path: Path) -> HostSample:
    io = psutil.disk_io_counters()
    return HostSample(
        elapsed_seconds=elapsed,
        cpu_utilization=psutil.cpu_percent(interval=None) / 100,
        memory_utilization=psutil.virtual_memory().percent / 100,
        swap_used_bytes=psutil.swap_memory().used,
        disk_free_bytes=psutil.disk_usage(str(disk_path)).free,
        disk_read_bytes=io.read_bytes if io else 0,
        disk_write_bytes=io.write_bytes if io else 0,
    )


def inspect_bundle(report: BuildReport) -> None:
    if report.result_bundle is None or not report.result_bundle.exists():
        return
    try:
        result = subprocess.run(
            ["xcrun", "xcresulttool", "get", "build-results", "--path", str(report.result_bundle), "--compact"],
            capture_output=True,
            timeout=10,
            check=False,
        )
        if result.returncode == 0:
            counts = BuildResults.model_validate_json(result.stdout)
            if counts.warningCount is not None:
                report.warnings = counts.warningCount
            if counts.errorCount is not None:
                report.errors = counts.errorCount
    except OSError, subprocess.TimeoutExpired, ValueError:
        report.observation_errors.append("Result-bundle inspection failed.")


def run_build(
    command: list[str],
    options: BuildOptions,
    metadata: dict[str, Attribute],
    *,
    add_xcode_flags: bool = True,
) -> BuildReport:
    build_id = str(uuid.uuid4())
    artifact_dir = options.artifact_dir.resolve() / build_id
    artifact_dir.mkdir(parents=True, mode=0o700)
    supplied_bundle = argument_value(command, "-resultBundlePath")
    bundle = Path(supplied_bundle).resolve() if supplied_bundle is not None else artifact_dir / "Build.xcresult"
    command = list(command)
    if add_xcode_flags:
        if "-showBuildTimingSummary" not in command:
            command.append("-showBuildTimingSummary")
        if supplied_bundle is None:
            command.extend(["-resultBundlePath", str(bundle)])
    report = BuildReport(build_id=build_id, exit_code=127, duration_seconds=0, metadata=metadata, result_bundle=bundle)
    metadata = {**metadata, "build.id": build_id}
    telemetry = Telemetry(False, "")
    try:
        telemetry = Telemetry(options.telemetry, str(metadata.get("host.model", "unknown")))
    except OSError, ValueError, RuntimeError, RequestException:
        report.observation_errors.append("Telemetry initialization failed. The build continues locally.")
    parser = BuildOutputParser()
    cancellation = Cancellation()
    with telemetry.build_span(metadata) as span, cancellation_handlers(cancellation):
        if add_xcode_flags:
            command.append(f"LOGFIRE_BUILD_ID={build_id}")
            context = trace.get_current_span().get_span_context()
            if telemetry.client is not None and context.is_valid:
                command.append(f"LOGFIRE_BUILD_TRACE_ID={context.trace_id:032x}")
        _execute(command, options, report, parser, cancellation, telemetry, artifact_dir)
        inspect_bundle(report)
        try:
            telemetry.complete(report, span)
        except OSError, ValueError, RuntimeError, RequestException:
            report.observation_errors.append("Build telemetry failed. The build exit code is unchanged.")
    try:
        report.telemetry_flushed = telemetry.flush()
    except OSError, ValueError, RuntimeError, RequestException:
        report.observation_errors.append("Telemetry export failed. The build exit code is unchanged.")
    if telemetry.enabled and not report.telemetry_flushed:
        report.observation_errors.append("Telemetry did not flush successfully.")
    if not bundle.exists():
        report.result_bundle = None
    report_path = artifact_dir / "report.json"
    report_path.write_text(report.model_dump_json(indent=2) + "\n")
    report_path.chmod(0o600)
    return report


def _execute(
    command: list[str],
    options: BuildOptions,
    report: BuildReport,
    parser: BuildOutputParser,
    cancellation: Cancellation,
    telemetry: Telemetry,
    artifact_dir: Path,
) -> None:
    started = time.monotonic()
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        report.observation_errors.append("The build executable could not start.")
        return
    output_streams: dict[int, BinaryIO | None] = {1: sys.stdout.buffer, 2: sys.stderr.buffer}
    buffers = {1: "", 2: ""}
    decoders = {number: codecs.getincrementaldecoder("utf-8")(errors="replace") for number in (1, 2)}
    cancellation_deadline: float | None = None
    next_sample = started + options.sample_interval
    sample_available = True
    sample_export_available = True
    log_path = artifact_dir / "build.log"
    try:
        psutil.cpu_percent(interval=None)
    except OSError, psutil.Error:
        sample_available = False
        report.observation_errors.append("Host sampling is unavailable.")
    try:
        with (
            selectors.DefaultSelector() as selector,
            log_path.open("wb") as output,
        ):
            log_path.chmod(0o600)
            for number, pipe in ((1, process.stdout), (2, process.stderr)):
                if pipe is not None:
                    selector.register(pipe, selectors.EVENT_READ, number)
            while selector.get_map() or process.poll() is None:
                now = time.monotonic()
                if cancellation.signum is not None and cancellation_deadline is None:
                    signal_group(process, cancellation.signum)
                    cancellation_deadline = now + 3
                if cancellation_deadline is not None and now >= cancellation_deadline:
                    signal_group(process, signal.SIGKILL)
                    cancellation_deadline = float("inf")
                if sample_available and now >= next_sample and process.poll() is None:
                    try:
                        sample = host_sample(now - started, Path.cwd())
                        report.samples.append(sample)
                    except OSError, psutil.Error, ValueError, RuntimeError:
                        sample_available = False
                        report.observation_errors.append("Host sampling stopped after an observation failure.")
                    else:
                        if sample_export_available:
                            try:
                                telemetry.sample(sample, report.build_id)
                            except OSError, ValueError, RuntimeError, RequestException:
                                sample_export_available = False
                                report.observation_errors.append("Host sample export failed. Local sampling continues.")
                    next_sample = now + options.sample_interval
                for key, _ in selector.select(timeout=0.1):
                    number = key.data
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    output.write(chunk)
                    stream = output_streams[number]
                    if stream is not None:
                        try:
                            stream.write(chunk)
                            stream.flush()
                        except OSError:
                            output_streams[number] = None
                    buffers[number] += decoders[number].decode(chunk)
                    while "\n" in buffers[number]:
                        line, buffers[number] = buffers[number].split("\n", 1)
                        parser.process(line)
            for number, buffer in buffers.items():
                parser.process(buffer + decoders[number].decode(b"", final=True))
            returncode = process.wait()
            report.exit_code = (
                128 + cancellation.signum
                if cancellation.signum is not None
                else (128 - returncode if returncode < 0 else returncode)
            )
    finally:
        if process.poll() is None:
            signal_group(process, signal.SIGKILL)
        process.wait()
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        report.duration_seconds = time.monotonic() - started
        report.timings = parser.timings
        report.warnings = parser.warnings
        report.errors = parser.errors
