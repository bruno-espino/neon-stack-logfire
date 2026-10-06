"""Run Xcode builds with optional telemetry and retained local reports."""

import argparse
import shutil
import sys
from pathlib import Path

from xcode_observe.build_identity import load_host_credentials
from xcode_observe.model import BuildOptions, build_metadata
from xcode_observe.runner import run_build


def main() -> int:
    parser = argparse.ArgumentParser(description="Observe an Xcode build and retain its result bundle.")
    parser.add_argument("--artifact-dir", type=Path, default=Path(".xcode-observe"))
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--cache-state", choices=("unknown", "cold", "warm"), default="unknown")
    parser.add_argument("--scenario", default="manual")
    parser.add_argument("--run-id")
    parser.add_argument("--no-telemetry", action="store_true")
    parser.add_argument("xcode_arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.xcode_arguments
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if arguments[:1] == ["xcodebuild"]:
        arguments = arguments[1:]
    if not arguments:
        parser.error("Supply xcodebuild arguments after --.")
    if args.sample_interval < 0.1:
        parser.error("--sample-interval must be at least 0.1 seconds.")
    executable = shutil.which("xcodebuild")
    if executable is None:
        print("xcode-observe: Select an Xcode installation first.", file=sys.stderr)
        return 127
    options = BuildOptions(
        artifact_dir=args.artifact_dir,
        sample_interval=args.sample_interval,
        cache_state=args.cache_state,
        scenario=args.scenario,
        run_id=args.run_id,
        telemetry=not args.no_telemetry,
    )
    load_host_credentials()
    report = run_build([executable, *arguments], options, build_metadata(arguments, options))
    report_path = options.artifact_dir.resolve() / report.build_id / "report.json"
    print(f"\nxcode-observe: exit {report.exit_code}, {report.duration_seconds:.2f}s", file=sys.stderr)
    print(f"Report: {report_path}", file=sys.stderr)
    if report.trace_id:
        print(f"Trace: {report.trace_id}", file=sys.stderr)
    for error in report.observation_errors:
        print(f"Observation: {error}", file=sys.stderr)
    return report.exit_code
