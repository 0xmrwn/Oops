"""Oops under test: the Debug build fixtures/e2e installs, launched with a stub provider, a debug log,
the lab triggers and a probe-state file, plus a stream of its Highlight log for the flash stage."""

import json
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "e2e"))
import run as e2e  # noqa: E402  (build, quit_oops, RUNTIME, TOOLS)

# Placements that anchor to the field or its caret; `window` and `screen` mean Oops found neither.
ANCHORED = {"composer", "composerBelow", "caret", "caretAbove"}


class Oops:
    def __init__(self, work):
        self.stub = work / "stub.json"
        self.log = work / "log"
        self.probe = work / "probe.json"
        self.highlights = []  # (time, rects) for each highlight_rects line
        self.pills = []  # (time, [(w, h)], (field w, field h)) for each word, from Debug's highlight_range lines
        self.stream = None

    @staticmethod
    def build(skip):
        e2e.build(skip)
        source, binary = Path(__file__).resolve().parent / "tools/flashes.swift", e2e.TOOLS / "flashes"
        if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
            subprocess.run(["swiftc", "-O", "-o", str(binary), str(source)], check=True)

    def start(self):
        e2e.quit_oops()
        self.stub.write_text("{}")
        subprocess.run(
            [
                "open",
                "-n",
                str(e2e.RUNTIME),
                "--args",
                "-StubProvider",
                str(self.stub),
                "-DebugLog",
                "YES",
                "-DebugLogDirectory",
                str(self.log),
                "-DiagnosticsRemoteTrigger",
                "YES",
                "-SoundsEnabled",
                "NO",
                "-ProbeState",
                str(self.probe),
            ],
            check=True,
        )
        self.stream = subprocess.Popen(
            [
                "/usr/bin/log",
                "stream",
                "--level",
                "info",
                "--style",
                "ndjson",
                "--predicate",
                'subsystem == "dev.0xmrwn.oops" AND category == "Highlight"',
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        threading.Thread(target=self.read_stream, daemon=True).start()
        time.sleep(3)

    def read_stream(self):
        for line in self.stream.stdout:
            try:
                message = json.loads(line).get("eventMessage", "")
            except ValueError:
                continue
            if message.startswith("highlight_rects") and "rects=" in message:
                rects = message.split("rects=")[1].split()[0]
                self.highlights.append((time.time(), int(rects) if rects.isdigit() else 0))
            elif message.startswith("highlight_range"):
                fields = dict(part.split("=", 1) for part in message.split()[1:] if "=" in part)
                size = lambda text: tuple(int(v) for v in text.split("x"))  # noqa: E731
                pills = [size(r) for r in fields.get("rects", "").split(",") if r]
                self.pills.append((time.time(), pills, size(fields.get("field", "0x0"))))

    def stop(self):
        if self.stream:
            self.stream.terminate()
        e2e.quit_oops()
        subprocess.run(["open", str(e2e.RUNTIME)])

    def answer(self, script):
        tmp = self.stub.with_suffix(".tmp")
        tmp.write_text(json.dumps(script, ensure_ascii=False))
        tmp.replace(self.stub)

    def entries(self, kind):
        lines = []
        for file in sorted(self.log.glob("corrections-*.jsonl")):
            lines += [json.loads(line) for line in file.read_text().splitlines() if line.strip()]
        return [e for e in lines if e["kind"] == kind]

    def trigger(self, name, marker):
        e2e.require_screen()
        subprocess.run([str(e2e.TOOLS / "activate"), marker], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.4)
        e2e.require_screen()
        subprocess.run([str(e2e.TOOLS / "trigger"), name], check=True)

    def wait(self, kind, count, seconds):
        deadline = time.time() + seconds
        checked = 0
        while time.time() < deadline:
            if time.time() >= checked:
                e2e.require_screen()
                checked = time.time() + 1
            found = self.entries(kind)
            if len(found) > count:
                e2e.require_screen()
                return found[count]
            time.sleep(0.1)
        return None

    def placement(self, bundle):
        """The capsule's last placement, read through the probe while `bundle` is in front."""
        before = self.probe.stat().st_mtime if self.probe.exists() else 0
        subprocess.run([str(e2e.TOOLS / "trigger"), "app", "read", bundle], check=True)
        deadline = time.time() + 4
        while time.time() < deadline:
            if self.probe.exists() and self.probe.stat().st_mtime != before:
                time.sleep(0.05)
                state = json.loads(self.probe.read_text())
                return state.get("placement") or f"none ({state.get('error') or 'no placement'})"
            time.sleep(0.05)
        return "none (no probe state)"

    def watch_flashes(self, seconds):
        """Starts recording the frames Oops's flash panel takes (tools/flashes.swift)."""
        return subprocess.Popen([str(e2e.TOOLS / "flashes"), str(seconds)], stdout=subprocess.PIPE, text=True)

    @staticmethod
    def flash_frames(watcher):
        watcher.terminate()
        output, _ = watcher.communicate()
        return [json.loads(line) for line in output.splitlines() if line.startswith("{")]

    def field_frame(self, bundle):
        """The focused field's frame (x, y, w, h) in Accessibility's coordinates, through the probe."""
        before = self.probe.stat().st_mtime if self.probe.exists() else 0
        subprocess.run([str(e2e.TOOLS / "trigger"), "app", "bounds", bundle], check=True)
        deadline = time.time() + 4
        while time.time() < deadline:
            if self.probe.exists() and self.probe.stat().st_mtime != before:
                time.sleep(0.05)
                lines = json.loads(self.probe.read_text()).get("outline") or [""]
                numbers = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", lines[0])]
                return numbers[:4] if len(numbers) >= 4 else None
            time.sleep(0.05)
        return None

    def flashed(self, since):
        return max((rects for at, rects in self.highlights if at >= since), default=None)

    def field_sized(self, since):
        """Word pills since `since` that cover nearly the whole field: a placeholder taken for a word's
        place, which lights up the entire draft instead of the word."""
        return [
            (w, h, field)
            for at, pills, field in self.pills
            if at >= since
            for w, h in pills
            if field[0] and field[1] and w >= 0.9 * field[0] and h >= 0.9 * field[1]
        ]
