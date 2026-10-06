"""Read aggregate task timings without inventing task boundaries."""

import re

TIMING = re.compile(r"^\s*(.+?)\s+(?:\(\d+\s+tasks?\)\s*\|\s*)?(\d+(?:\.\d+)?)\s+seconds?\s*$")


class BuildOutputParser:
    def __init__(self) -> None:
        self.timings: dict[str, float] = {}
        self.warnings = 0
        self.errors = 0
        self.in_summary = False

    def process(self, line: str) -> None:
        self.warnings += bool(re.search(r"\bwarning:", line, re.IGNORECASE))
        self.errors += bool(re.search(r"\berror:", line, re.IGNORECASE))
        if line.strip() == "Build Timing Summary":
            self.in_summary = True
        elif self.in_summary and (match := TIMING.match(line)):
            name, duration = match.groups()
            self.timings[name] = self.timings.get(name, 0.0) + float(duration)
        elif self.in_summary and line.strip():
            self.in_summary = False
