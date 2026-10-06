"""Embed build identity in the app without embedding host credentials."""

import argparse
import hashlib
import json
import os
import subprocess
import uuid
from pathlib import Path

from opentelemetry import trace
from requests.exceptions import RequestException

from xcode_observe.dev_relay import STATE
from xcode_observe.telemetry import Telemetry


def load_host_credentials() -> None:
    path = STATE / "credentials.env"
    if path.is_file():
        for line in path.read_text().splitlines():
            key, separator, value = line.partition("=")
            if separator and key in {"LOGFIRE_TOKEN", "LOGFIRE_BASE_URL"}:
                os.environ.setdefault(key, value)


def git_commit(source: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=5, check=False
    )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def source_digest(roots: list[Path]) -> str:
    digest = hashlib.sha256()
    for index, root in enumerate(roots):
        files = sorted(
            path
            for path in ([root] if root.is_file() else root.rglob("*"))
            if path.is_file()
            and not any(part.startswith(".") for part in path.relative_to(root).parts)
            and (path.suffix in {".swift", ".metal", ".pbxproj"} or path.name == "Package.resolved")
        )
        for path in files:
            digest.update(f"{index}/{path.name if root.is_file() else path.relative_to(root)}\0".encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--package", required=True, type=Path)
    args = parser.parse_args()
    build_id = (
        str(uuid.UUID(os.environ["LOGFIRE_BUILD_ID"])) if os.environ.get("LOGFIRE_BUILD_ID") else str(uuid.uuid4())
    )
    metadata = {
        "build.id": build_id,
        "git.commit": git_commit(args.source),
        "build.source_digest": source_digest(
            [
                args.source / "NeonStack",
                args.source / "NeonStack.xcodeproj",
                args.package / "Sources",
                args.package / "Package.swift",
            ]
        ),
        "build.configuration": os.environ.get("CONFIGURATION", "unknown"),
        "build.sdk": os.environ.get("SDK_NAME", "unknown"),
        "xcode.version": os.environ.get("XCODE_VERSION_ACTUAL", "unknown"),
    }
    if value := os.environ.get("LOGFIRE_BUILD_TRACE_ID"):
        metadata["build.trace_id"] = value
    else:
        try:
            load_host_credentials()
            telemetry = Telemetry(True, "local")
            if telemetry.client is not None:
                with telemetry.client.span("xcode.build.identity") as span:
                    span.set_attributes(metadata)
                    metadata["build.trace_id"] = format(trace.get_current_span().get_span_context().trace_id, "032x")
                telemetry.flush()
        except OSError, ValueError, RuntimeError, RequestException:
            print("Build identity export unavailable. The app retains its local identity.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".tmp")
    temporary.write_text(json.dumps(metadata, indent=2) + "\n")
    temporary.replace(args.output)
    print(f"App build identity: {build_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
