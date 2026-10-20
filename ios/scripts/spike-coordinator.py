"""The host side of SpikeNotificationTests (SPIKE, docs/ios/demo/m1).

A tiny HTTP server on 127.0.0.1 that the UI test, running in the simulator, calls:

  GET  /cases          the test setup (setup.json in the work directory)
  GET  /log            the app group's spike-log.jsonl (the handler's events, completion included)
  GET  /push/<case>    `xcrun simctl push <udid> com.bahumia.quickr payload-<case>.json`; answers
                       once the push has been delivered (a barrier, not a sleep)
  POST /result/<case>  what the test observed, saved as result-<case>.json

Usage: spike-coordinator.py <udid> <work dir> <port file>. Writes the chosen port to <port file>.
"""

import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

udid, work, port_file = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status: int, body: bytes = b"{}") -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/cases":
            self._reply(200, (work / "setup.json").read_bytes())
        elif self.path.startswith("/push/"):
            name = self.path.removeprefix("/push/")
            payload = work / f"payload-{name}.json"
            done = subprocess.run(
                ["xcrun", "simctl", "push", udid, "com.bahumia.quickr", str(payload)],
                capture_output=True,
                text=True,
                check=False,
            )
            (work / f"push-{name}.log").write_text(done.stdout + done.stderr)
            self._reply(
                200 if done.returncode == 0 else 500,
                json.dumps({"exit": done.returncode}).encode(),
            )
        elif self.path == "/log":
            # The app group's spike log (one JSON object per line), as JSON lines.
            group = subprocess.run(
                ["xcrun", "simctl", "get_app_container", udid, "com.bahumia.quickr", "group.com.bahumia.quickr"],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
            log = Path(group) / "Library/quickr/spike-log.jsonl"
            self._reply(200, log.read_bytes() if group and log.exists() else b"")
        else:
            self._reply(404)

    def do_POST(self) -> None:  # noqa: N802
        if self.path.startswith("/result/"):
            length = int(self.headers.get("Content-Length", "0"))
            (work / f"result-{self.path.removeprefix('/result/')}.json").write_bytes(
                self.rfile.read(length)
            )
            self._reply(200)
        else:
            self._reply(404)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        sys.stderr.write("spike-coordinator: " + format % args + "\n")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
