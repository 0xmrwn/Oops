#!/usr/bin/env python3
"""End-to-end runs of the real correction pipeline against the labs, with a stub provider.

Builds Oops (Debug, so the stub exists) and installs it as the development runtime, launches it
with launch-argument-only settings (stub provider, debug log in a temporary folder, lab triggers,
no sounds), drives each scenario and checks the lab's final text and the attempt Oops logged, then
what each further press of Fix text did (`toggle:` cases), counting the stub's calls. No model is called.
`insert-` cases write text at the caret instead (inserts.py). Native scenarios run in fixtures/native-lab; web ones run fixtures/e2e/web.html,
served here, in each browser host: WebKit (the native lab's web view), Chrome and Zen (Gecko), the
browsers with throwaway profiles. Fronts the lab windows: don't run it while someone is using the
Mac. Leaves Oops relaunched as normal and no defaults or profiles behind.

Usage: fixtures/e2e/run.py [--no-build] [--full] [--soak N] [filter ...]
A filter is a scenario name, a host (native, webkit, chrome, zen) or a prefix ending at a colon
(chrome:textarea); web scenarios are named host:editor:case. No filter runs the quick set (every native
case, WebKit's composer and textarea, one case per bake-off failure class); --full runs everything.
--soak N repeats the scenarios N times and reports Oops's memory, threads, open files and child
processes after the first round and at the end, to catch leaks and strays.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import inserts
from scenarios import QUICK, SCENARIOS

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / ".build" / "lab-tools"
LAB_APP = TOOLS / "NativeLab.app"
LAB_MARKER = "NativeLab.app/Contents/MacOS/NativeLab"
RUNTIME = Path.home() / "Library/Application Support/oops/Development/oops.app"
CHROME = Path("/Applications/Google Chrome.app")
ZEN = Path("/Applications/Zen.app")
# A fresh Zen profile without its welcome flow, default-browser prompt or update checks.
ZEN_PREFS = {
    "zen.welcome-screen.seen": True,
    "browser.shell.checkDefaultBrowser": False,
    "browser.aboutwelcome.enabled": False,
    "browser.startup.homepage_override.mstone": "ignore",
    "datareporting.policy.dataSubmissionPolicyBypassNotification": True,
    "app.update.auto": False,
}


def sh(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


class ScreenUnavailable(RuntimeError):
    """The run has no valid screen, rather than an editor failing a case."""


def require_screen():
    state = json.loads(sh(str(TOOLS / "session"), capture_output=True, text=True).stdout)
    if state["blocked"]:
        reason = "the Mac is locked" if state["locked"] else f"a system dialog has focus ({state['front']})"
        raise ScreenUnavailable(f"Screen run stopped: {reason}. Clear it before retrying; these are not Oops failures.")


def quit_oops():
    """Ends Oops and waits for it: an `open` that still finds it running reopens its Settings."""
    subprocess.run(["pkill", "-x", "oops"])
    deadline = time.time() + 5
    while time.time() < deadline and subprocess.run(["pgrep", "-x", "oops"], stdout=subprocess.DEVNULL).returncode == 0:
        time.sleep(0.1)


def build(skip):
    TOOLS.mkdir(parents=True, exist_ok=True)
    for tool in ["trigger", "activate", "session"]:
        source = ROOT / "fixtures/composer-lab/tools" / f"{tool}.swift"
        binary = TOOLS / tool
        if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
            sh("swiftc", "-O", "-o", str(binary), str(source))
    require_screen()
    source = ROOT / "fixtures/native-lab/NativeLab.swift"
    binary = LAB_APP / "Contents/MacOS/NativeLab"
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        binary.parent.mkdir(parents=True, exist_ok=True)
        sh("swiftc", "-O", "-o", str(binary), str(source))
        (LAB_APP / "Contents/Info.plist").write_text("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NativeLab</string>
<key>CFBundleIdentifier</key><string>dev.0xmrwn.oops-native-lab</string>
<key>CFBundleName</key><string>oops native lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
""")
        sh("codesign", "--force", "--sign", "-", str(LAB_APP), stdout=subprocess.DEVNULL)
    if skip:
        return
    sh(str(ROOT / "script/build_and_run.sh"), "--build-only", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    quit_oops()
    shutil.rmtree(RUNTIME, ignore_errors=True)
    sh("ditto", "--norsrc", "--noextattr", str(ROOT / "dist/oops.app"), str(RUNTIME))


def serve(run):
    """fixtures/e2e/web.html, the current control at /control, and the page's posted text in web.state."""
    page = (ROOT / "fixtures/e2e/web.html").read_bytes()
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            control = self.path.startswith("/control")
            try:
                body = run.lab.read_bytes() if control else page
            except OSError:
                body = b"{}"
            self.send_response(200)
            self.send_header("Content-Type", "application/json" if control else "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            with lock:
                (run.work / "web.state.tmp").write_bytes(body)
                (run.work / "web.state.tmp").replace(run.work / "web.state")
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class Run:
    def __init__(self, work):
        self.work = work
        self.stub = work / "stub.json"
        self.lab = work / "lab.json"
        self.log = work / "log"
        self.nonce = 0
        self.host = "native"
        self.profile = None  # The running Chrome's or Zen's throwaway profile.
        self.fresh = False  # The host's page has yet to load.
        self.capture = None  # How Oops read the last draft.
        self.server = serve(self)
        self.url = f"http://127.0.0.1:{self.server.server_port}/"

    def write(self, path, value):
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(value))
        tmp.replace(path)

    def state(self):
        try:
            if self.host == "native":
                return json.loads((self.work / "lab.json.state").read_text())
            state = json.loads((self.work / "web.state").read_text())
            return state if state.get("host") == self.host else {}
        except (OSError, ValueError):
            return {}

    def entries(self):
        lines = []
        for file in sorted(self.log.glob("corrections-*.jsonl")):
            lines += [json.loads(line) for line in file.read_text().splitlines() if line.strip()]
        return lines

    def wait(self, check, seconds, what):
        deadline = time.time() + seconds
        checked = 0
        while time.time() < deadline:
            if time.time() >= checked:
                require_screen()
                checked = time.time() + 1
            value = check()
            if value:
                require_screen()
                return value
            time.sleep(0.1)
        raise TimeoutError(what)

    def trigger(self, name, *arguments):
        require_screen()
        sh(str(TOOLS / "activate"), str(self.profile) if self.profile else LAB_MARKER, stdout=subprocess.DEVNULL)
        time.sleep(0.4)
        require_screen()
        sh(str(TOOLS / "trigger"), name, *arguments)

    def control(self, scenario, **fields):
        self.nonce += 1
        control = {"scenario": scenario, "nonce": str(self.nonce), "host": self.host, **fields}
        if self.host == "webkit":
            control["url"] = f"{self.url}?host=webkit"
        self.write(self.lab, control)

    def show(self, scenario, text=None, selection=None, variant=None):
        fields = {"text": text} if text is not None else {}
        if selection:
            fields["selection"] = selection
        if variant:
            fields["variant"] = variant
        self.control(scenario, **fields)
        # A browser starting, or a page loading, takes a while the first time.
        seconds, self.fresh = (30 if self.fresh else 5), False
        self.wait(lambda: self.state().get("nonce") == str(self.nonce), seconds, "lab did not switch scenario")

    def use(self, host):
        """Moves to a host: Chrome and Zen open with a throwaway profile, and close when the run moves on."""
        if host == self.host:
            return
        self.close()
        self.host, self.fresh = host, host != "native"
        if host not in ("chrome", "zen"):
            return
        self.profile = Path(tempfile.mkdtemp(prefix=f"oops-e2e-{host}-"))
        url = f"{self.url}?host={host}"
        if host == "chrome":
            options = ["--no-first-run", "--no-default-browser-check", "--disable-sync", "--window-size=1100,760"]
            sh("open", "-na", str(CHROME), "--args", f"--user-data-dir={self.profile}", *options, f"--app={url}")
        else:
            prefs = "".join(f"user_pref({json.dumps(k)}, {json.dumps(v)});\n" for k, v in ZEN_PREFS.items())
            (self.profile / "user.js").write_text(prefs)
            sh("open", "-na", str(ZEN), "--args", "-profile", str(self.profile), "-no-remote", url)
            # Oops wakes Gecko's accessibility once it has a window; a field this local page focused
            # before then would read as the whole page until focus moves (docs/compatibility.md).
            time.sleep(3)

    def close(self):
        if not self.profile:
            return
        subprocess.run(["pkill", "-f", str(self.profile)])
        deadline = time.time() + 10
        while (
            time.time() < deadline
            and subprocess.run(["pgrep", "-f", str(self.profile)], capture_output=True).returncode == 0
        ):
            time.sleep(0.2)
        subprocess.run(["pkill", "-9", "-f", str(self.profile)])
        shutil.rmtree(self.profile, ignore_errors=True)
        self.profile = None

    def scenario(self, case, round=0):
        case = json.loads(json.dumps(case).replace("{round}", str(round)))
        self.use(case.get("host", "native"))
        self.capture = None
        if "insert" in case:
            return inserts.check(self, case)
        self.write(self.stub, case["stub"])
        self.show(case.get("scenario", "e2e"), case.get("text"), case.get("selection"), case.get("variant"))
        before = len([e for e in self.entries() if e["kind"] == "attempt"])
        self.trigger("correct-lab")
        if "append" in case:
            time.sleep(0.5)
            self.control(case.get("scenario", "e2e"), append=case["append"])
        attempts = self.wait(
            lambda: [e for e in self.entries() if e["kind"] == "attempt"][before:], 20, "no attempt was logged"
        )
        attempt = attempts[0]
        self.capture = (attempt.get("editor") or {}).get("capture")
        time.sleep(0.4)
        problems = []

        def expect(label, actual, wanted):
            if actual != wanted:
                problems.append(f"{label}: wanted {wanted!r}, got {actual!r}")

        expect("outcome", attempt.get("outcome"), case["outcome"])
        if "stage" in case:
            expect("failed stage", attempt.get("failedStage"), case["stage"])
        if "reason" in case:
            expect("reason", attempt.get("reason"), case["reason"])
        expect("dropped changes", len(attempt.get("dropped") or []), case.get("dropped", 0))
        if "capture" in case:
            expect("capture", (attempt.get("editor") or {}).get("capture"), case["capture"])
        if case.get("no_model"):
            expect("model asked", "model" in attempt or "raw" in attempt, False)
        final = case.get("final", case.get("text"))
        if final is not None:
            expect("text", self.state().get("text"), final)
        if case.get("restore") and not problems:
            reverts = len([e for e in self.entries() if e["kind"] == "revert"])
            self.trigger("restore-lab")
            self.wait(
                lambda: len([e for e in self.entries() if e["kind"] == "revert"]) > reverts, 10, "no revert was logged"
            )
            time.sleep(0.4)
            expect("restored text", self.state().get("text"), case["text"])
            revert = [e for e in self.entries() if e["kind"] == "revert"][-1]
            expect("reverted attempt", revert.get("attempt"), attempt.get("id"))
        for number, step in enumerate(case.get("then", []), start=2):
            if not problems:
                problems += [f"press {number}: {problem}" for problem in self.press_again(case, step, attempt)]
        if problems and attempt.get("error"):
            problems.append(f"error: {attempt['error']}")
        return problems

    def calls(self):
        """How many times the stub was asked, as it counts itself."""
        try:
            return int(self.stub.with_suffix(".json.calls").read_text())
        except (OSError, ValueError):
            return 0

    def press_again(self, case, step, first):
        """Fix text pressed again (D10), after typing (`append`) or in another field (`other`): a `revert`
        or `reapply` label on the first attempt without asking the stub, or a new `attempt` that asks it.
        Returns the problems found."""
        if "stub" in step:
            self.write(self.stub, step["stub"])
        if "append" in step or "other" in step:
            wanted = self.state().get("text", "") + step["append"] if "append" in step else step["other"]
            fields = {"append": step["append"]} if "append" in step else {"other": step["other"]}
            self.control(case.get("scenario", "e2e"), **fields)
            self.wait(lambda: self.state().get("text") == wanted, 5, "lab did not take the edit")
        kind = step["expect"]

        def logged():
            return [e for e in self.entries() if e["kind"] == kind]

        before, calls = len(logged()), self.calls()
        self.trigger("correct-lab")
        self.wait(lambda: len(logged()) > before, 20, f"no {kind} was logged")
        time.sleep(0.4)
        entry = logged()[-1]
        found = [
            ("outcome", entry.get("outcome"), step["outcome"])
            if kind == "attempt"
            else (f"{kind} attempt", entry.get("attempt"), first.get("id")),
            ("stub calls", self.calls() - calls, 1 if kind == "attempt" else 0),
            ("text", self.state().get("text"), step["text"]),
        ]
        return [f"{label}: wanted {want!r}, got {actual!r}" for label, actual, want in found if actual != want]


def resources():
    """Oops's footprint (MB), threads, open files and child processes, or None when it isn't running."""
    pid = subprocess.run(["pgrep", "-x", "oops"], capture_output=True, text=True).stdout.split()
    if not pid:
        return None
    pid = pid[0]
    footprint = subprocess.run(["footprint", "-p", pid], capture_output=True, text=True).stdout
    mb = next((line.split()[1] for line in footprint.splitlines() if "phys_footprint:" in line), "?")
    threads = len(subprocess.run(["ps", "-M", "-p", pid], capture_output=True, text=True).stdout.splitlines()) - 1
    files = len(subprocess.run(["lsof", "-p", pid], capture_output=True, text=True).stdout.splitlines()) - 1
    children = len(subprocess.run(["pgrep", "-P", pid], capture_output=True, text=True).stdout.split())
    return {"footprint_mb": mb, "threads": threads, "open_files": files, "children": children}


def main():
    args = sys.argv[1:]
    soak = 1
    if "--soak" in args:
        i = args.index("--soak")
        soak = int(args[i + 1])
        del args[i : i + 2]
    args = [a for a in args if a not in ("--no-build", "--full")]

    def matches(case, filter):
        return filter in (case["name"], case.get("host", "native")) or case["name"].startswith(filter.rstrip(":") + ":")

    unknown = [a for a in args if not any(matches(c, a) for c in SCENARIOS)]
    if unknown:
        sys.exit(f"unknown scenario: {', '.join(unknown)}")
    everything = "--full" in sys.argv
    cases = [c for c in SCENARIOS if (any(matches(c, a) for a in args) if args else everything or c["name"] in QUICK)]
    missing = {"chrome": CHROME, "zen": ZEN}
    for host, app in missing.items():
        if not app.exists() and any(c.get("host") == host for c in cases):
            print(f"skipping {host}: {app} is not installed")
            cases = [c for c in cases if c.get("host") != host]
    build("--no-build" in sys.argv)
    work = Path(tempfile.mkdtemp(prefix="oops-e2e-"))
    run = Run(work)
    lab = None
    failures = 0
    try:
        quit_oops()
        sh(
            "open",
            "-n",
            str(RUNTIME),
            "--args",
            "-StubProvider",
            str(run.stub),
            "-DebugLog",
            "YES",
            "-DebugLogDirectory",
            str(run.log),
            "-DiagnosticsRemoteTrigger",
            "YES",
            "-SoundsEnabled",
            "NO",
        )
        run.write(run.lab, {"scenario": "e2e", "nonce": "0", "text": ""})
        lab = subprocess.Popen(
            [str(LAB_APP / "Contents/MacOS/NativeLab"), str(run.lab), str(ROOT / "fixtures/composer-lab/index.html")]
        )
        time.sleep(3)
        started = time.time()
        before = None
        for index, case in enumerate(cases * soak):
            # The first round loads what any first correction loads; leaks show up after it.
            if soak > 1 and index == len(cases):
                time.sleep(6)
                before = resources()
            try:
                problems = run.scenario(case, index // len(cases))
            except TimeoutError as error:
                problems = [str(error)]
            failures += bool(problems)
            # Web editors can be read several ways: show which one this browser took.
            via = f"  ({run.capture})" if "host" in case and run.capture else ""
            print(("ok    " if not problems else "FAIL  ") + case["name"] + via)
            for problem in problems:
                print("        " + problem)
        print(f"\n{len(cases) * soak - failures}/{len(cases) * soak} passed in {time.time() - started:.0f}s")
        if before:
            time.sleep(6)  # Let the last drop, flash and Claude grace period end.
            print(f"before: {before}\nafter:  {resources()}")
    finally:
        run.close()
        run.server.shutdown()
        if lab:
            lab.terminate()
        quit_oops()
        subprocess.run(["open", str(RUNTIME)])
        shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
