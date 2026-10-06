"""Export build spans and host observations with bounded shutdown."""

import os
import platform
import socket
import uuid
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

import logfire
from opentelemetry import trace
from pydantic import SecretStr

from xcode_observe.model import Attribute, BuildReport, HostSample


def preserve_observation_id(match: logfire.ScrubMatch) -> str | None:
    if match.path[-1] in {"session_id", "game.session_id", "sessionID"} and isinstance(match.value, str):
        try:
            identifier = uuid.UUID(match.value)
        except ValueError:
            return None
        if identifier.version == 4:
            return match.value
    return None


class Telemetry:
    def __init__(self, enabled: bool, host_model: str) -> None:
        token_value = os.environ.get("LOGFIRE_TOKEN")
        self.enabled = enabled and (bool(token_value) or Path(".logfire/logfire_credentials.json").is_file())
        self.client: logfire.Logfire | None = None
        if not self.enabled:
            return
        token = SecretStr(token_value) if token_value else None
        os.environ.setdefault("OTEL_METRIC_EXPORT_INTERVAL", "1000")
        self.client = logfire.configure(
            local=True,
            service_name="xcode-observe",
            token=token.get_secret_value() if token is not None else None,
            console=False,
            inspect_arguments=False,
            scrubbing=logfire.ScrubbingOptions(callback=preserve_observation_id),
            resource_attributes={
                "host.name": socket.gethostname(),
                "host.type": host_model,
                "host.arch": platform.machine(),
                "os.type": "darwin",
                "os.description": platform.platform(),
            },
            advanced=logfire.AdvancedOptions(base_url=os.environ.get("LOGFIRE_BASE_URL")),
        )
        self.duration = self.client.metric_histogram("xcode.build.duration", unit="s")
        self.builds = self.client.metric_counter("xcode.build.total", unit="1")
        self.cpu = self.client.metric_gauge("system.cpu.simple_utilization", unit="1")
        self.memory = self.client.metric_gauge("system.memory.utilization", unit="1")
        self.disk_free = self.client.metric_gauge("system.filesystem.usage", unit="By")

    @contextmanager
    def build_span(self, metadata: dict[str, Attribute]) -> Generator[logfire.LogfireSpan | None]:
        if self.client is None:
            yield None
            return
        with self.client.span("xcode.build") as span:
            for name, value in metadata.items():
                span.set_attribute(name, value)
            yield span

    def sample(self, sample: HostSample, build_id: str) -> None:
        if self.client is None:
            return
        self.cpu.set(sample.cpu_utilization)
        self.memory.set(sample.memory_utilization, attributes={"state": "used"})
        self.memory.set(1 - sample.memory_utilization, attributes={"state": "available"})
        self.disk_free.set(sample.disk_free_bytes, attributes={"state": "free", "mountpoint": "/"})
        self.client.info("xcode.host.sample", **{"build.id": build_id}, **sample.model_dump())

    def complete(self, report: BuildReport, span: logfire.LogfireSpan | None) -> None:
        if self.client is None or span is None:
            return
        values: dict[str, Attribute] = {
            "build.id": report.build_id,
            "build.exit_code": report.exit_code,
            "build.success": report.exit_code == 0,
            "build.duration_seconds": report.duration_seconds,
            "xcode.warning_count": report.warnings,
            "xcode.error_count": report.errors,
            "host.sample_count": len(report.samples),
        }
        for name, value in values.items():
            span.set_attribute(name, value)
        span.set_attribute("xcode.task_seconds", report.timings)
        if report.exit_code:
            span.set_level("error")
        context = trace.get_current_span().get_span_context()
        if context.is_valid:
            report.trace_id = format(context.trace_id, "032x")
        dimensions = {
            k: v
            for k, v in report.metadata.items()
            if k
            in {
                "build.scheme",
                "build.configuration",
                "build.actions",
                "build.cache_state",
                "xcode.version",
                "host.model",
            }
        }
        dimensions["outcome"] = "success" if report.exit_code == 0 else "failure"
        self.duration.record(report.duration_seconds, attributes=dimensions)
        self.builds.add(1, attributes=dimensions)

    def flush(self) -> bool:
        return self.client.force_flush(timeout_millis=3000) if self.client is not None else False
