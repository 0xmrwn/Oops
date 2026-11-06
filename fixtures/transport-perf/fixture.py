"""Canned HTTP/1.1 responses with independent socket ordinals."""

import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

RESPONSE = json.dumps(
    {"choices": [{"finish_reason": "stop", "message": {"content": '{"text":"This is a test."}'}}]},
    separators=(",", ":"),
).encode("utf-8")


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, run_id, pairs, tls=None, close_after_first=False):
        self.run_id = run_id
        self.pairs = pairs
        self.tls = tls
        self.close_after_first = close_after_first
        self.lock = Lock()
        self.connections = 0
        self.rejected = 0
        self.errors = 0
        self.requests = {}
        super().__init__(("127.0.0.1", 0), Handler)

    def get_request(self):
        connection, address = super().get_request()
        if self.tls is not None:
            try:
                connection = self.tls.wrap_socket(connection, server_side=True, do_handshake_on_connect=False)
            except (OSError, ValueError):
                connection.close()
                raise
        return connection, address

    def new_connection(self):
        with self.lock:
            self.connections += 1
            return self.connections

    def record(self, pair, connection, tls):
        with self.lock:
            requests = self.requests.setdefault(pair, [])
            if len(requests) == 2:
                return None
            position = len(requests) + 1
            row = {"pair": pair, "position": position, "connection": connection}
            if tls is not None:
                row["tlsVersion"], row["tlsSessionResumed"] = tls
            requests.append(row)
            return position

    def snapshot(self):
        with self.lock:
            return {
                "connections": self.connections,
                "rejected": self.rejected,
                "handlerErrors": self.errors,
                "requests": [row for requests in self.requests.values() for row in requests],
            }

    def handle_error(self, request, client_address):
        with self.lock:
            self.errors += 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(8)
        self.connection_number = self.server.new_connection()

    def log_message(self, format, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.reject(code)

    def reject(self, status):
        with self.server.lock:
            self.server.rejected += 1
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_POST(self):
        parts = self.path.split("/")
        if len(parts) != 6 or parts[:2] != ["", self.server.run_id] or parts[3:] != ["v1", "chat", "completions"]:
            self.reject(404)
            return
        try:
            pair = int(parts[2])
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.reject(400)
            return
        if not (1 <= pair <= self.server.pairs and parts[2] == str(pair) and 0 < length <= 16384) or any(
            header in self.headers for header in ("Authorization", "Proxy-Authorization", "Cookie")
        ):
            self.reject(400)
            return
        # Drain the body to allow HTTP/1.1 reuse without retaining any request content.
        if len(self.rfile.read(length)) != length:
            self.reject(400)
            return
        tls = None
        if isinstance(self.connection, ssl.SSLSocket):
            tls = self.connection.version(), self.connection.session_reused
        position = self.server.record(pair, self.connection_number, tls)
        if position is None:
            self.reject(400)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(RESPONSE)))
        self.send_header("Cache-Control", "no-store")
        if position == 1 and self.server.close_after_first:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(RESPONSE)
