import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import httpx2
import pytest
from pydantic import SecretStr

from xcode_observe.dev_relay import Relay


@pytest.mark.parametrize("path", ["/v1/traces", "/v1/metrics"])
def test_relay_preserves_otlp_and_injects_only_host_credential(path: str) -> None:
    received: list[tuple[str, str | None, bytes]] = []

    class Upstream(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            body = self.rfile.read(int(self.headers["Content-Length"]))
            received.append((self.path, self.headers.get("Authorization"), body))
            self.send_response(200)
            self.send_header("Content-Type", "application/x-protobuf")
            self.end_headers()
            self.wfile.write(b"")

        def log_message(self, format: str, *args: object) -> None:
            pass

    upstream = HTTPServer(("127.0.0.1", 0), Upstream)
    relay = Relay(("127.0.0.1", 0), f"http://127.0.0.1:{upstream.server_port}", SecretStr("synthetic-write-token"))
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (upstream, relay)]
    for thread in threads:
        thread.start()
    try:
        url = f"http://127.0.0.1:{relay.server_port}"
        result = httpx2.post(
            url + path,
            content=b"protobuf-bytes",
            headers={
                "Content-Type": "application/x-protobuf",
                "Authorization": "Bearer app-value",
            },
        )
        assert result.status_code == 200
        assert received == [(path, "Bearer synthetic-write-token", b"protobuf-bytes")]
        health = httpx2.get(url + "/health").json()
        assert health["forwarded"] == 1
        assert "synthetic-write-token" not in str(health)
        assert httpx2.post(url + path, content=b"x", headers={"Content-Type": "text/plain"}).status_code == 415
        assert httpx2.post(url + "/wrong", content=b"x").status_code == 404
        assert len(received) == 1
        relay.endpoint = f"http://127.0.0.1:{relay.server_port}/missing"
        # An upstream failure never becomes a successful acknowledgement.
        upstream.shutdown()
        upstream.server_close()
        relay.endpoint = f"http://127.0.0.1:{upstream.server_port}"
        assert (
            httpx2.post(
                url + path, content=b"x", headers={"Content-Type": "application/x-protobuf"}
            ).status_code
            == 502
        )
        assert httpx2.get(url + "/health").json()["failed"] == 1
    finally:
        relay.shutdown()
        upstream.shutdown()
        relay.client.close()
        relay.server_close()
        upstream.server_close()
        for thread in threads:
            thread.join(timeout=2)
