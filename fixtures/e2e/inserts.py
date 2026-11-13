"""Insert cases for fixtures/e2e/run.py: text written at the lab's caret by the `insert-lab` trigger."""

import json
import subprocess
import time


def clipboard():
    """The clipboard's text, only ever read: it is the real one, and a run must leave it as it was."""
    return subprocess.run(["pbpaste"], capture_output=True).stdout


def logged(run):
    """What Oops said of each lab insert, one line each."""
    try:
        return [json.loads(line) for line in (run.log / "inserts.jsonl").read_text().splitlines() if line.strip()]
    except OSError:
        return []


def check(run, case):
    """Shows the case's field, inserts its text and returns the problems found: the outcome Oops reported,
    the field's text, that no correction was attempted, and that the clipboard came back."""
    run.show(case.get("scenario", "e2e"), case.get("text"), case.get("selection"), case.get("variant"))
    shown, copied, before = run.state().get("text"), clipboard(), len(logged(run))
    attempts = len([e for e in run.entries() if e["kind"] == "attempt"])
    run.trigger("insert-lab", case["insert"])
    insert = run.wait(lambda: logged(run)[before:], 10, "no insert was logged")[0]
    time.sleep(0.4)
    # A refused insert leaves the field as it was shown.
    found = [
        ("outcome", insert.get("outcome"), case["expect"]),
        ("reason", insert.get("reason"), case.get("reason")),
        ("text", run.state().get("text"), case.get("final", shown)),
        ("attempts", len([e for e in run.entries() if e["kind"] == "attempt"]), attempts),
    ]
    problems = [f"{label}: wanted {wanted!r}, got {actual!r}" for label, actual, wanted in found if actual != wanted]
    # Oops gives the clipboard back half a second after the paste. Its contents are never printed.
    time.sleep(0.8)
    if clipboard() != copied:
        problems.append("clipboard: not what it held before the insert")
    return problems
