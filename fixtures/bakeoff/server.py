#!/usr/bin/env python3
"""The bake-off's local web server: the page and the vendored engines, the current case at /control,
and each shell's posted state at /state. Native shells poll the same two endpoints."""

import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOTS = {"/vendor/": HERE / "vendor", "/": HERE / "web"}
TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript",
    ".css": "text/css",
    ".json": "application/json; charset=utf-8",
}


class V6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


class Server:
    def __init__(self):
        self.control = {}
        self.states = {}  # host -> the last state it posted
        self.lock = threading.Lock()
        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                path = self.path.split("?")[0]
                if path == "/control":
                    with server.lock:
                        return self.reply(200, json.dumps(server.control, ensure_ascii=False).encode(), TYPES[".json"])
                if path == "/":
                    path = "/page.html"
                for prefix, root in ROOTS.items():
                    if path.startswith(prefix):
                        file = (root / path[len(prefix) :]).resolve()
                        if file.is_relative_to(root) and file.is_file():
                            return self.reply(
                                200, file.read_bytes(), TYPES.get(file.suffix, "application/octet-stream")
                            )
                self.reply(404, b"not found", "text/plain")

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                try:
                    state = json.loads(body)
                    with server.lock:
                        server.states[state.get("host")] = state
                except ValueError:
                    pass
                self.reply(204, b"", "text/plain")

            def reply(self, status, body, kind):
                self.send_response(status)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.http.server_port
        # "localhost" may resolve to ::1 first: answer there too, on the same port, for cross-origin frames.
        try:
            self.http6 = V6(("::1", self.port), Handler)
            threading.Thread(target=self.http6.serve_forever, daemon=True).start()
        except OSError:
            self.http6 = None
        self.url = f"http://127.0.0.1:{self.port}/"
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    def show(self, host, nonce, case, **extra):
        with self.lock:
            self.control = {"host": host, "nonce": str(nonce), "case": case, **extra}

    def state(self, host):
        with self.lock:
            return dict(self.states.get(host) or {})

    def stop(self):
        self.http.shutdown()
        if self.http6:
            self.http6.shutdown()


if __name__ == "__main__":
    # A person poking at the page (selftest.html) without the runner.
    import time

    print(f"{Server().url}selftest.html", flush=True)
    while True:
        time.sleep(3600)
