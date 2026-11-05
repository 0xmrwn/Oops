#!/usr/bin/env python3
"""Compatibility probe: Oops's real capture, apply, revert and highlight in installed apps, with a stub provider.

For each app: open a scratch editor, paste a draft with two typos and a mention between them, correct it,
revert it, then delete that draft again. A field that already holds text is skipped, never cleared. The stub answers with the typos fixed, so no model is called and nothing
is ever sent. Results print as a Markdown table for docs/compatibility.md and go to --out as JSON.

Fronts each app in turn and types into it: run it only when nobody is using the Mac. Oops is installed as
the development runtime (like fixtures/e2e) and relaunched as normal at the end.

Usage: fixtures/compat/run.py [--no-build] [--out FILE] [app ...]
"""

import functools
import http.server
import json
import plistlib
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "e2e"))
import run as e2e  # noqa: E402  (build, quit_oops, RUNTIME, TOOLS)

LAB = Path(__file__).resolve().parents[1] / "composer-lab/index.html"
DRAFT = "teh @alice docs need a smal update"
FIXED = DRAFT.replace("teh", "the").replace("smal", "small")


def installed(bundle):
    folders = [Path("/Applications"), Path("/System/Applications"), Path.home() / "Applications"]
    for app in (a for folder in folders for a in folder.glob("*.app")):
        try:
            if plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier") == bundle:
                return True
        except (OSError, ValueError):
            continue
    return False


def obsidian_vault():
    config = Path.home() / "Library/Application Support/obsidian/obsidian.json"
    try:
        vaults = json.loads(config.read_text())["vaults"].values()
        return next((Path(v["path"]) for v in vaults if v.get("open")), None)
    except (OSError, ValueError, KeyError):
        return None


# name, bundle id, how to open a scratch editor (shell argv lists), whether ⌘N makes one, and whether the
# field is Oops's own scratch (the composer lab's sample text may be replaced). Claude and Teams are left
# out: their composers are real conversations, and Claude's window may be the one running this probe.
APPS = [
    dict(name="TextEdit", bundle="com.apple.TextEdit", open=[["open", "-a", "TextEdit", "{scratch}/compat.txt"]]),
    dict(name="Notes", bundle="com.apple.Notes", open=[["open", "-a", "Notes"]], new=True),
    dict(name="Mail", bundle="com.apple.mail", open=[["open", "mailto:?subject=Oops%20probe"]], focus="web"),
    dict(
        name="Safari textarea",
        bundle="com.apple.Safari",
        open=[["open", "-a", "Safari", "{lab}?probe=textarea#chat-textarea"]],
        scratch=True,
    ),
    dict(
        name="Safari contenteditable",
        bundle="com.apple.Safari",
        open=[["open", "-a", "Safari", "{lab}?probe=contenteditable#chat"]],
        scratch=True,
    ),
    dict(
        name="Chrome textarea",
        bundle="com.google.Chrome",
        open=[["open", "-a", "Google Chrome", "{lab}?probe=textarea#chat-textarea"]],
        scratch=True,
    ),
    dict(
        name="Chrome contenteditable",
        bundle="com.google.Chrome",
        open=[["open", "-a", "Google Chrome", "{lab}?probe=contenteditable#chat"]],
        scratch=True,
    ),
    dict(
        name="Zen textarea",
        bundle="app.zen-browser.zen",
        open=[["open", "-a", "Zen", "{lab}?probe=textarea#chat-textarea"]],
        scratch=True,
    ),
    dict(
        name="Zen contenteditable",
        bundle="app.zen-browser.zen",
        open=[["open", "-a", "Zen", "{lab}?probe=contenteditable#chat"]],
        scratch=True,
    ),
    dict(name="Obsidian", bundle="md.obsidian", obsidian=True, focus="largest"),
    dict(name="Notion", bundle="notion.id", open=[["open", "-a", "Notion"]], new=True, optional=True),
]


class LabHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


class Probe:
    def __init__(self, work, lab_url):
        self.work = work
        self.lab_url = lab_url
        self.stub = work / "stub.json"
        self.state_file = work / "state.json"
        self.log = work / "log"

    def trigger(self, action, bundle, text=None):
        args = [str(e2e.TOOLS / "trigger"), "app", action, bundle] + ([text] if text is not None else [])
        before = self.state_file.stat().st_mtime if self.state_file.exists() else 0
        subprocess.run(args, check=True)
        if action in ("correct", "restore"):
            return None
        deadline = time.time() + 5
        while time.time() < deadline:
            if self.state_file.exists() and self.state_file.stat().st_mtime != before:
                time.sleep(0.05)
                return json.loads(self.state_file.read_text())
            time.sleep(0.05)
        return {"ok": False, "error": "no probe state"}

    def entries(self, kind):
        lines = []
        for file in sorted(self.log.glob("corrections-*.jsonl")):
            lines += [json.loads(line) for line in file.read_text().splitlines() if line.strip()]
        return [e for e in lines if e["kind"] == kind]

    def wait_for(self, kind, count, seconds=20):
        deadline = time.time() + seconds
        while time.time() < deadline:
            found = self.entries(kind)
            if len(found) > count:
                return found[count]
            time.sleep(0.1)
        return None

    def highlights(self, since):
        out = subprocess.run(
            [
                "/usr/bin/log",
                "show",
                "--info",
                "--style",
                "compact",
                "--start",
                since,
                "--predicate",
                'subsystem == "dev.0xmrwn.oops" AND category == "Highlight" AND eventMessage BEGINSWITH "highlight_rects"',
            ],
            capture_output=True,
            text=True,
        ).stdout
        rects = [line.split("rects=")[1].split()[0] for line in out.splitlines() if "rects=" in line]
        return [int(r) for r in rects if r.isdigit()]

    @staticmethod
    def scratch_field(state):
        return state.get("ok") and state.get("role") == "AXTextArea" and state.get("fieldDescription") == "Message"

    def app(self, spec):
        result = {"app": spec["name"], "bundle": spec["bundle"]}
        if spec.get("optional"):
            result["optional"] = True
        if not installed(spec["bundle"]):
            return {**result, "capture": "not installed"}
        if spec.get("obsidian"):
            vault = obsidian_vault()
            if not vault:
                return {**result, "capture": "no open vault"}
            note = f"Oops probe {int(time.time())}"
            result["cleanup"] = str(vault / f"{note}.md")
            commands = [
                ["open", f"obsidian://new?vault={vault.name.replace(' ', '%20')}&name={note.replace(' ', '%20')}"]
            ]
        else:
            commands = [
                [part.replace("{scratch}", str(self.work)).replace("{lab}", self.lab_url) for part in c]
                for c in spec["open"]
            ]
        for command in commands:
            subprocess.run(command, check=False)
        time.sleep(4)
        subprocess.run(["open", "-b", spec["bundle"]])
        time.sleep(1.5)
        bundle = spec["bundle"]
        if spec.get("new"):
            self.trigger("new", bundle)
            time.sleep(1.5)
        focus = "largest" if spec.get("scratch") else spec.get("focus")
        state = self.trigger("focus", bundle, focus)
        if spec.get("scratch") and not self.scratch_field(state):
            # Gecko follows a field only after focus moves once its accessibility tree wakes.
            subprocess.run(
                [str(e2e.TOOLS / "activate"), "Finder.app/Contents/MacOS/Finder"], check=True, capture_output=True
            )
            time.sleep(0.3)
            subprocess.run(["open", "-b", bundle], check=True)
            time.sleep(0.5)
            state = self.trigger("focus", bundle, focus)
        if spec.get("scratch") and not self.scratch_field(state):
            return {**result, "capture": "fixture error: expected the lab's Message text area", "state": state}
        if not state.get("ok"):
            return {**result, "capture": f"no editor: {state.get('error')}"}
        if (state.get("value") or "").strip() and not spec.get("scratch"):
            return {**result, "field": state.get("role"), "capture": "skipped: the field already has text"}
        state = self.trigger("replace" if spec.get("scratch") else "type", bundle, DRAFT)
        value = state.get("value") or state.get("markerText")
        result["field"] = "/".join(filter(None, [state.get("role"), state.get("subrole")]))
        if spec.get("scratch") and (value or "").strip() != DRAFT:
            return {
                **result,
                "capture": "fixture error: scratch replacement did not leave only the probe draft",
                "state": state,
            }
        if value is None or DRAFT not in value:
            result["capture"] = f"draft not readable ({result['field'] or 'no role'})"
            result["state"] = state
            return result
        # A real model takes seconds; Chrome's accessibility switch needs two before text has geometry.
        self.stub.write_text(json.dumps({"answer": value.replace(DRAFT, FIXED), "delayMs": 2500}))
        attempts = len(self.entries("attempt"))
        since = time.strftime("%Y-%m-%d %H:%M:%S")
        self.trigger("correct", bundle)
        attempt = self.wait_for("attempt", attempts)
        time.sleep(1.5)
        after = self.trigger("read", bundle)
        if not attempt:
            result["capture"] = "no attempt logged"
            return result
        result["capture"] = "ok" if attempt.get("failedStage") != "capture" else f"fails: {attempt.get('error')}"
        result["apply"] = (
            "ok"
            if attempt["outcome"] == "fixed" and FIXED in (after.get("value") or after.get("markerText") or "")
            else f"{attempt['outcome']}: {attempt.get('error') or 'text differs'}"
            if attempt.get("failedStage") != "capture"
            else "–"
        )
        rects = self.highlights(since)
        result["highlight"] = (
            (f"{rects[0]} rects" if rects and rects[0] > 0 else "none placed") if result["apply"] == "ok" else "–"
        )
        result["placement"] = after.get("placement") or "–"
        result["timings"] = attempt.get("timings")
        if result["apply"] == "ok":
            reverts = len(self.entries("revert"))
            self.trigger("restore", bundle)
            reverted = self.wait_for("revert", reverts, 10)
            time.sleep(1)
            back = self.trigger("read", bundle)
            result["revert"] = (
                "ok" if reverted and DRAFT in (back.get("value") or back.get("markerText") or "") else "fails"
            )
        else:
            result["revert"] = "–"
        return result


def table(results):
    rows = ["| App | Field | Capture | Apply | Revert | Highlight | Placement |", "|---|---|---|---|---|---|---|"]
    for r in results:
        rows.append(
            f"| {r['app']} | {r.get('field') or '–'} | {r.get('capture', '–')} | {r.get('apply', '–')} | "
            f"{r.get('revert', '–')} | {r.get('highlight', '–')} | {r.get('placement', '–')} |"
        )
    return "\n".join(rows)


def failed_result(result):
    capture = result.get("capture", "")
    if capture.startswith(("not installed", "no open vault", "skipped:")):
        return False
    if capture.startswith("no editor:") and result.get("optional"):
        return False
    return not (
        capture == "ok"
        and result.get("apply") == "ok"
        and result.get("revert") == "ok"
        and result.get("highlight", "").endswith(" rects")
        and not result["highlight"].startswith("0 ")
    )


def main():
    args = sys.argv[1:]
    out = None
    if "--out" in args:
        i = args.index("--out")
        out = Path(args[i + 1])
        del args[i : i + 2]
    names = [a for a in args if a != "--no-build"]
    apps = [a for a in APPS if not names or a["name"] in names or a["bundle"] in names]
    e2e.build("--no-build" in sys.argv)
    work = Path(tempfile.mkdtemp(prefix="oops-compat-"))
    (work / "compat.txt").write_text("")
    handler = functools.partial(LabHandler, directory=str(LAB.parent))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    probe = Probe(work, f"http://127.0.0.1:{server.server_port}/index.html")
    results = []
    try:
        e2e.quit_oops()
        subprocess.run(
            [
                "open",
                "-n",
                str(e2e.RUNTIME),
                "--args",
                "-StubProvider",
                str(probe.stub),
                "-DebugLog",
                "YES",
                "-DebugLogDirectory",
                str(probe.log),
                "-DiagnosticsRemoteTrigger",
                "YES",
                "-SoundsEnabled",
                "NO",
                "-ProbeState",
                str(probe.state_file),
            ],
            check=True,
        )
        time.sleep(3)
        for spec in apps:
            try:
                result = probe.app(spec)
            except Exception as error:  # one app's trouble shouldn't end the run
                result = {"app": spec["name"], "bundle": spec["bundle"], "capture": f"probe error: {error}"}
            finally:
                # Whatever happened, the probe's own text goes (only that text: it can't match anything else).
                for text in (FIXED, DRAFT):
                    probe.trigger("remove", spec["bundle"], text)
            if result.get("cleanup"):
                Path(result["cleanup"]).unlink(missing_ok=True)
            results.append(result)
            print(
                f"{result['app']}: {result.get('capture')} / {result.get('apply', '–')} / {result.get('revert', '–')} / {result.get('highlight', '–')}",
                flush=True,
            )
    finally:
        server.shutdown()
        server.server_close()
        e2e.quit_oops()
        subprocess.run(["open", str(e2e.RUNTIME)])
    print("\n" + table(results))
    if out:
        out.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
    return int(any(failed_result(result) for result in results))


if __name__ == "__main__":
    raise SystemExit(main())
