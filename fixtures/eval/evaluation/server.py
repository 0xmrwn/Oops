"""A loopback-only report and review website. It exposes no inference or shell endpoint."""

import json
import secrets
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .campaign import save_label
from .records import ROOT, read_json, run_directory
from .scoring import case_detail, generating, report


def serve(runs, port=8766):
    token = secrets.token_urlsafe(32)
    cache, cache_lock = {}, threading.Lock()
    assets = {
        "/": ROOT / "dashboard/index.html",
        "/style.css": ROOT / "dashboard/style.css",
        "/app.js": ROOT / "dashboard/app.js",
        "/review.js": ROOT / "dashboard/review.js",
        "/live.js": ROOT / "dashboard/live.js",
        "/diff.js": ROOT / "app/diff.js",
    }

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, value, status=200, mime="application/json"):
            data = json.dumps(value, ensure_ascii=False).encode() if mime == "application/json" else value
            self.send_response(status)
            self.send_header("Content-Type", mime + "; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'",
            )
            self.end_headers()
            self.wfile.write(data)

        def location(self):
            parsed = urllib.parse.urlparse(self.path)
            return parsed.path, {k: v[-1] for k, v in urllib.parse.parse_qs(parsed.query).items()}

        def state(self, name):
            folders = (
                sorted(
                    [p for p in runs.iterdir() if p.is_dir() and (p / "manifest.json").exists()],
                    key=lambda p: (p / "manifest.json").stat().st_mtime,
                    reverse=True,
                )
                if runs.exists()
                else []
            )
            names = [p.name for p in folders]
            if not names:
                return {"runs": [], "run": None, "dataset": read_json(ROOT / "dataset.json"), "token": token}
            directory = run_directory(runs, name or names[0])
            stamp = tuple(
                (str(p.relative_to(directory)), p.stat().st_mtime_ns, p.stat().st_size)
                for p in sorted(directory.rglob("*"))
                if p.is_file() and p.suffix in {".json", ".jsonl"}
            )
            stamp += (("rubric", (ROOT / "rubric.json").stat().st_mtime_ns),)
            with cache_lock:
                if cache.get("identity") != (directory, stamp):
                    cache.update(identity=(directory, stamp), value=report(directory))
                value = {**cache["value"], "runs": names, "token": token, "generating": generating(directory)}
                progress = directory / "judge_progress.json"
                value["judge_progress"] = read_json(progress) if progress.exists() else None
                if (
                    value["judge_progress"]
                    and value["judge_progress"]["status"] == "running"
                    and not generating(directory, ".judging.lock")
                ):
                    value["judge_progress"] = {**value["judge_progress"], "status": "interrupted"}
            return value

        def do_GET(self):
            if self.headers.get("Host") != f"127.0.0.1:{self.server.server_port}":
                return self.send({"error": "Use the printed loopback URL."}, 403)
            path, query = self.location()
            try:
                if path in assets:
                    mime = "text/html" if path == "/" else "text/css" if path.endswith(".css") else "text/javascript"
                    return self.send(assets[path].read_bytes(), mime=mime)
                if path == "/api/state":
                    return self.send(self.state(query.get("run")))
                if path == "/api/case":
                    return self.send(case_detail(run_directory(runs, query.get("run")), query.get("id")))
                self.send({"error": "Not found."}, 404)
            except (ValueError, OSError, KeyError) as error:
                self.send(
                    {
                        "error": str(error)
                        if isinstance(error, ValueError)
                        else "Run data is unavailable. Refresh after the writer finishes."
                    },
                    400,
                )

        def do_POST(self):
            path, query = self.location()
            origin = self.headers.get("Origin")
            permitted = f"http://127.0.0.1:{self.server.server_port}"
            if self.headers.get("X-Oops-Token") != token or (origin and origin != permitted):
                return self.send({"error": "Reload the local dashboard before saving."}, 403)
            if path != "/api/labels":
                return self.send({"error": "Not found."}, 404)
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 1_048_576:
                    raise ValueError("Review payload must be under 1 MiB.")
                payload = json.loads(self.rfile.read(length))
                directory = run_directory(runs, query.get("run"))
                return self.send(
                    save_label(directory, payload["key"], payload["judgment"], read_json(ROOT / "rubric.json"))
                )
            except (ValueError, OSError, KeyError, TypeError) as error:
                return self.send(
                    {
                        "error": str(error)
                        if isinstance(error, ValueError)
                        else "Review could not be saved. Reload this case."
                    },
                    400,
                )

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Oops Eval: http://127.0.0.1:{server.server_port} (local only; Ctrl+C stops)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
