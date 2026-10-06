"""Forward local development OTLP without putting a write token in the app."""

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Literal

import httpx2
from pydantic import BaseModel, SecretStr

PORT = 4318
PROTOCOL = "logfire-swift-dev-v1"
STATE = Path.home() / ".config/xcode-observe"


class RelayHealth(BaseModel):
    protocol: Literal["logfire-swift-dev-v1"] = PROTOCOL
    pid: int
    forwarded: int
    failed: int


class Relay(HTTPServer):
    def __init__(self, address: tuple[str, int], endpoint: str, token: SecretStr):
        super().__init__(address, Handler)
        self.endpoint = endpoint
        self.token = token
        self.forwarded = 0
        self.failed = 0
        self.last_request = time.monotonic()
        self.timeout = 1
        self.client = httpx2.Client(timeout=3, follow_redirects=False)


class Handler(BaseHTTPRequestHandler):
    @property
    def relay(self) -> Relay:
        if not isinstance(self.server, Relay):
            raise RuntimeError("The handler requires a development relay")
        return self.server

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(2)

    def log_message(self, format: str, *args: object) -> None:
        pass

    def reply(self, status: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path != "/health":
            self.reply(404, b"{}")
            return
        self.reply(
            200,
            json.dumps(
                {
                    "protocol": PROTOCOL,
                    "pid": os.getpid(),
                    "forwarded": self.relay.forwarded,
                    "failed": self.relay.failed,
                }
            ).encode(),
        )

    def do_POST(self) -> None:
        if self.path not in {"/v1/traces", "/v1/metrics"}:
            self.reply(404, b"{}")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.reply(400, b"{}")
            return
        if not 0 < length <= 4 * 1024 * 1024:
            self.reply(413, b"{}")
            return
        content_type = self.headers.get("Content-Type", "")
        if content_type not in {"application/json", "application/x-protobuf"}:
            self.reply(415, b"{}")
            return
        body = self.rfile.read(length)
        if len(body) != length:
            self.reply(400, b"{}")
            return
        self.relay.last_request = time.monotonic()
        headers = {"Content-Type": content_type, "Authorization": f"Bearer {self.relay.token.get_secret_value()}"}
        if encoding := self.headers.get("Content-Encoding"):
            headers["Content-Encoding"] = encoding
        try:
            response = self.relay.client.post(self.relay.endpoint + self.path, content=body, headers=headers)
        except httpx2.HTTPError:
            self.relay.failed += 1
            self.reply(502, b"{}")
            return
        if response.is_success:
            self.relay.forwarded += 1
            self.reply(response.status_code, response.content, response.headers.get("Content-Type", content_type))
        else:
            self.relay.failed += 1
            self.reply(502, b"{}")


def status() -> RelayHealth | None:
    try:
        response = httpx2.get(f"http://127.0.0.1:{PORT}/health", timeout=5)
        response.raise_for_status()
        data = RelayHealth.model_validate_json(response.content)
    except httpx2.ConnectError:
        return None
    return data


def serve(credentials: Path) -> None:
    values = dict(
        line.split("=", 1) for line in credentials.read_text().splitlines() if line and not line.startswith("#")
    )
    token = SecretStr(values["LOGFIRE_TOKEN"])
    if not token:
        raise ValueError("LOGFIRE_TOKEN must contain a project write token")
    endpoint = values["LOGFIRE_BASE_URL"].rstrip("/")
    if endpoint not in {"https://logfire-us.pydantic.dev", "https://logfire-eu.pydantic.dev"}:
        raise ValueError("Use a Logfire region endpoint")
    with Relay(("127.0.0.1", PORT), endpoint, token) as server:
        try:
            while time.monotonic() - server.last_request < 3600:
                server.handle_request()
        finally:
            server.client.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "stop", "status", "serve"])
    parser.add_argument("--credentials", type=Path, default=STATE / "credentials.env")
    args = parser.parse_args()
    if args.action == "serve":
        serve(args.credentials)
        return 0
    current = status()
    if args.action == "stop":
        if current is not None:
            os.kill(current.pid, signal.SIGTERM)
        print("Development relay stopped")
        return 0
    if current is None and args.action == "start":
        if not args.credentials.is_file():
            raise ValueError(f"Configure the private credential file at {args.credentials}")
        STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
        logfile = STATE / "relay.log"
        logfile.touch(mode=0o600)
        with logfile.open("ab") as output:
            child = subprocess.Popen(
                [sys.executable, "-m", "xcode_observe.dev_relay", "serve", "--credentials", str(args.credentials)],
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=output,
                start_new_session=True,
            )
        for _ in range(30):
            current = status()
            if current is not None:
                break
            if child.poll() is not None:
                raise RuntimeError(f"Relay startup failed. Read {logfile}")
            time.sleep(0.1)
        if current is None:
            child.terminate()
            raise RuntimeError("Relay startup timed out")
    print(current.model_dump_json() if current is not None else json.dumps({"status": "stopped"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
