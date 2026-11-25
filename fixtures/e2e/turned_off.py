"""Turned-off cases for fixtures/e2e/run.py: Fix pressed in the lab with Oops turned off in it, then the drop's
Turn on, pressed by the `turned-off-lab` trigger. Oops logs the drop before and after the press in turn-on.jsonl."""

import json
import time

TURNED_OFF = [
    # Named, with Turn on: the model is never asked, the draft stays, and Oops is on in the lab after the press.
    dict(name="turned-off", text="teh docs", stub={"answer": "x"}, turned_off=True),
]


def logged(run):
    try:
        return [json.loads(line) for line in (run.log / "turn-on.jsonl").read_text().splitlines() if line.strip()]
    except OSError:
        return []


def check(run, case):
    """Turns Oops off in the lab, presses Fix, then Turn on; returns the problems found."""
    run.write(run.stub, case["stub"])
    run.show(case.get("scenario", "e2e"), case["text"])
    attempts, calls = len([e for e in run.entries() if e["kind"] == "attempt"]), run.calls()
    run.trigger("turned-off-lab", "off")
    run.trigger("correct-lab")
    try:
        attempt = run.wait(
            lambda: [e for e in run.entries() if e["kind"] == "attempt"][attempts:], 20, "no attempt was logged"
        )[0]
        time.sleep(0.4)
        found = [
            ("outcome", attempt.get("outcome"), "failed"),
            ("failed stage", attempt.get("failedStage"), "capture"),
            ("reason", attempt.get("reason"), "turnedOff"),
            ("stub calls", run.calls() - calls, 0),
            ("text", run.state().get("text"), case["text"]),
        ]
    finally:
        # Pressed even when Fix went wrong: with nothing to press, the trigger still turns the lab back on.
        before = len(logged(run))
        run.trigger("turned-off-lab", "on")
        pressed = run.wait(lambda: logged(run)[before:], 10, "Turn on was not logged")[0]
    found += [
        ("pressed", pressed.get("pressed"), "true"),
        ("drop before", pressed.get("shown", "").startswith("Off in "), True),
        ("on after", pressed.get("on"), "true"),
        ("drop after", pressed.get("drop"), "fixed"),
        ("label after", pressed.get("label", "").startswith("On in "), True),
    ]
    return [f"{label}: wanted {wanted!r}, got {actual!r}" for label, actual, wanted in found if actual != wanted]
