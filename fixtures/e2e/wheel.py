"""Wheel cases for fixtures/e2e/run.py: the Actions wheel opened on the lab's draft and driven by trigger. Carbon never
hears posted keys, so the shortcut has a trigger of its own; keys and the pointer go through the wheel's own tap.
Oops logs every effect, refusal, state and outcome in actions.jsonl, which the checks read.

Steps: ("shortcut",), ("key", name, phase), ("keys", spec), ("mouse", kind, at), ("wait", ms), ("state",),
("outcome",) to wait for the next run's outcome, ("fix",) to run Fix on the draft and wait for its attempt, and
("probe",) to ask whether a posted key reaches the tap. Expectations: `outcomes` in order, `seen` effects in order
("select=down"), `unseen` effects, `counts` of an effect, `state` fields of the last state logged, the field's `final`
text (the shown text by default) and the stub's `calls`."""

import json
import time

import inserts

CARDINAL = dict(text="we should probably meet sometime next week to talk", stub={"answer": "let's meet next week"})
CHOICE = dict(text="good morning", stub={"answer": "bonjour"})
OPEN = [("shortcut",), ("wait", 400)]

WHEEL = [
    dict(
        name="wheel:cardinal",
        **CARDINAL,
        steps=OPEN + [("key", "down", "tap")],
        outcomes=["written"],
        seen=["bloom=up,right,down,left", "select=down", "run=Shorten"],
        final="let's meet next week",
        calls=1,
    ),
    dict(
        name="wheel:choice",
        **CHOICE,
        steps=OPEN + [("key", "right", "tap"), ("wait", 300), ("key", "up", "tap")],
        outcomes=["written"],
        seen=["select=right", "bloomChoices=up,right,down,left", "run=Translate/French"],
        final="bonjour",
        calls=1,
    ),
    dict(
        name="wheel:click",
        **CARDINAL,
        steps=OPEN + [("mouse", "move", "right"), ("wait", 100), ("mouse", "click", "down")],
        outcomes=["written"],
        seen=["point=right", "select=down", "run=Shorten"],
        final="let's meet next week",
        calls=1,
    ),
    # The result drop is up: the same direction puts the original back, without asking the model again.
    dict(
        name="wheel:restore",
        **CARDINAL,
        steps=OPEN
        + [("key", "down", "tap"), ("outcome",), ("shortcut",), ("wait", 300), ("state",), ("key", "down", "tap")],
        outcomes=["written", "restored"],
        seen=["run=Shorten", "select=down", "restore"],
        state={"title.down": "Restore"},
        calls=1,
    ),
    # A choice's direction restores at once: its ring is not asked again.
    dict(
        name="wheel:choice-restore",
        **CHOICE,
        steps=OPEN
        + [("key", "right", "tap"), ("wait", 300), ("key", "up", "tap"), ("outcome",)]
        + [("shortcut",), ("wait", 300), ("key", "right", "tap")],
        outcomes=["written", "restored"],
        seen=["run=Translate/French", "restore"],
        counts={"bloomChoices": 1},
        calls=1,
    ),
    # Past the result drop (5 s at launch) the direction runs again.
    dict(
        name="wheel:after-window",
        **CARDINAL,
        steps=OPEN + [("key", "down", "tap"), ("outcome",), ("wait", 5600)] + OPEN + [("key", "down", "tap")],
        outcomes=["written", "written"],
        unseen=["restore"],
        final="let's meet next week",
        calls=2,
    ),
    # Escape closes with an arrow still held; the arrow's key-up is still taken, then the tap goes.
    dict(
        name="wheel:escape",
        text="keep me",
        stub={"answer": "x"},
        steps=OPEN + [("keys", "right,30,escape,30,escape-,100,right-"), ("wait", 1200), ("state",)],
        outcomes=[],
        seen=["key=yes", "key=yes", "key=yes", "key=yes"],
        unseen=["run", "key=no"],
        state={"open": "no", "tapLive": "no"},
        calls=0,
    ),
    dict(
        name="wheel:diagonal",
        text="a long and winding draft about many things",
        stub={"answer": "summary"},
        library={"add": [{"name": "Summarize", "symbol": "text.alignleft", "place": "upRight"}]},
        steps=[("shortcut",), ("wait", 500), ("keys", "up+right,40,up-,30,right-")],
        outcomes=["written"],
        seen=["bloom=up,right,down,left,upRight", "select=upRight", "run=Summarize"],
        final="summary",
        calls=1,
    ),
    dict(
        name="wheel:neutral",
        text="keep me",
        stub={"answer": "x"},
        steps=OPEN + [("keys", "up+down,40,up-,down-"), ("wait", 200), ("state",)],
        outcomes=[],
        unseen=["run", "select"],
        state={"level": "root", "open": "yes"},
        calls=0,
    ),
    # An arrow before the wheel is up: no petal ever blooms, and the release runs it.
    dict(
        name="wheel:flick",
        **CARDINAL,
        steps=[("keys", "open,down,20,down-")],
        outcomes=["written"],
        seen=["skipBloom", "select=down", "run=Shorten"],
        unseen=["bloom"],
        final="let's meet next week",
        calls=1,
    ),
    # An arrow just after the petals start out: they go back in, and the release runs it.
    dict(
        name="wheel:flick-late",
        **CARDINAL,
        steps=[("keys", "open,60,down,20,down-")],
        outcomes=["written"],
        seen=["bloom=up,right,down,left", "skipBloom", "select=down", "run=Shorten"],
        final="let's meet next week",
        calls=1,
    ),
    dict(
        name="wheel:empty-place",
        text="keep me",
        stub={"answer": "x"},
        library={"places": ["up", "right", "down"]},
        steps=OPEN + [("key", "left", "tap"), ("wait", 200), ("state",)],
        outcomes=[],
        seen=["bloom=up,right,down"],
        unseen=["run", "select"],
        state={"level": "root", "open": "yes"},
        calls=0,
    ),
    dict(
        name="wheel:no-actions",
        text="keep me",
        stub={"answer": "x"},
        library={"places": []},
        steps=OPEN + [("key", "up", "tap"), ("wait", 200), ("state",)],
        outcomes=[],
        seen=["bloom="],
        unseen=["run", "select"],
        state={"level": "root", "open": "yes"},
        calls=0,
    ),
    dict(
        name="wheel:busy",
        **CARDINAL,
        stub_delay=1500,
        steps=[("shortcut",), ("wait", 400), ("key", "down", "tap"), ("wait", 300), ("shortcut",)],
        outcomes=["written"],
        seen=["run=Shorten", "refused=busy"],
        final="let's meet next week",
        calls=1,
    ),
    # Fix's drop up: the wheel stays shut and the status line says why. Its drop is waited out after.
    dict(
        name="wheel:fix-showing",
        text="teh docs need a smal update",
        stub={"answer": "the docs need a small update"},
        steps=[("fix",), ("shortcut",), ("wait", 300), ("state",)],
        outcomes=[],
        seen=["refused=fix"],
        unseen=["bloom"],
        state={"open": "no"},
        final="the docs need a small update",
        calls=1,
        settle=True,
    ),
    # Typing, Return and Delete go to the wheel, never to the draft.
    dict(
        name="wheel:keys-held",
        text="keep me",
        stub={"answer": "x"},
        steps=OPEN
        + [("key", "a", "tap"), ("key", "return", "tap"), ("key", "delete", "tap"), ("key", "escape", "tap")],
        outcomes=[],
        seen=["key=yes", "key=yes", "key=yes", "key=yes"],
        unseen=["key=no", "run"],
        calls=0,
    ),
    # Whether a key posted at the HID level reaches the tap: printed, never failed.
    dict(
        name="wheel:tap-reach",
        text="keep me",
        stub={"answer": "x"},
        steps=OPEN + [("probe",), ("wait", 300), ("key", "escape", "tap")],
        informational=True,
    ),
]

# The field an effect is told by, in "name=value".
FIELDS = {
    "bloom": "places",
    "bloomChoices": "places",
    "select": "place",
    "point": "place",
    "run": "invocation",
    "refused": "reason",
    "key": "taken",
}


def logged(run):
    try:
        return [json.loads(line) for line in (run.log / "actions.jsonl").read_text().splitlines() if line.strip()]
    except OSError:
        return []


def matches(event, spec):
    name, _, value = spec.partition("=")
    if event.get("wheel") != name:
        return False
    return "=" not in spec or event.get(FIELDS.get(name, ""), "") == value


def check(run, case):
    """Drives the case's steps and returns the problems found."""
    stub = dict(case.get("stub", {"answer": "ok"}))
    if "stub_delay" in case:
        stub["delayMs"] = case["stub_delay"]
    run.write(run.stub, stub)
    library = run.work / "library.json"
    library.write_text(json.dumps(case.get("library", {})))
    run.show(case.get("scenario", "e2e"), case.get("text"), case.get("selection"))
    before, calls, copied = len(logged(run)), run.calls(), inserts.clipboard()
    run.trigger("wheel-library", str(library))
    attempts = len([e for e in run.entries() if e["kind"] == "attempt"])

    def new():
        return logged(run)[before:]

    def outcomes():
        return [e["outcome"] for e in new() if "outcome" in e]

    # Outcomes the steps have waited for so far: each `outcome` step waits for the next one of the case, which may
    # already have landed while the step before it ran.
    consumed = 0
    for step in case["steps"]:
        kind = step[0]
        if kind == "shortcut":
            run.trigger("wheel-shortcut")
        elif kind == "key":
            run.trigger("wheel-key", step[1], step[2])
        elif kind == "keys":
            run.trigger("wheel-keys", step[1])
        elif kind == "mouse":
            run.trigger("wheel-mouse", step[1], step[2])
        elif kind == "state":
            run.trigger("wheel-state")
        elif kind == "probe":
            run.trigger("wheel-tap-probe")
        elif kind == "wait":
            time.sleep(step[1] / 1000)
        elif kind == "outcome":
            consumed += 1
            run.wait(lambda wanted=consumed: len(outcomes()) >= wanted, 20, "no outcome was logged")
        elif kind == "fix":
            run.trigger("correct-lab")
            run.wait(lambda: len([e for e in run.entries() if e["kind"] == "attempt"]) > attempts, 20, "Fix never ran")
            time.sleep(0.4)
    wanted = case.get("outcomes", [])
    if wanted:
        run.wait(lambda: len(outcomes()) >= len(wanted), 20, "no outcome was logged")
    time.sleep(0.6)
    events = [e for e in new() if "wheel" in e]
    if case.get("informational"):
        probe = next((e for e in events if e["wheel"] == "tap-probe"), {})
        print(f"        a key posted at the HID level reached the tap: {probe.get('seen', 'unknown')}")
        finish(run, case)
        return []
    final = case.get("final", case.get("text"))
    found = [("outcomes", outcomes(), wanted), ("text", run.state().get("text"), final)]
    if "calls" in case:
        found.append(("stub calls", run.calls() - calls, case["calls"]))
    problems = [f"{label}: wanted {wanted!r}, got {actual!r}" for label, actual, wanted in found if actual != wanted]
    rest = iter(events)
    problems += [f"never saw {spec}" for spec in case.get("seen", []) if not any(matches(e, spec) for e in rest)]
    problems += [f"saw {spec}" for spec in case.get("unseen", []) if any(matches(e, spec) for e in events)]
    for spec, count in case.get("counts", {}).items():
        if (seen := len([e for e in events if matches(e, spec)])) != count:
            problems.append(f"{spec}: wanted {count}, got {seen}")
    states = [e for e in events if e["wheel"] == "state"]
    for key, value in case.get("state", {}).items():
        if (got := (states[-1] if states else {}).get(key)) != value:
            problems.append(f"state {key}: wanted {value!r}, got {got!r}")
    if problems:
        problems.append(
            "events: "
            + " ".join(
                e["wheel"] + ("=" + e.get(FIELDS[e["wheel"]], "") if e["wheel"] in FIELDS else "") for e in events
            )
        )
    finish(run, case)
    if inserts.clipboard() != copied:
        problems.append("clipboard: not what it held before the wheel")
    return problems


def finish(run, case):
    """Leaves nothing open for the next case: the wheel shut, the Actions drop gone, Fix's drop waited out."""
    run.trigger("wheel-key", "escape", "tap")
    run.trigger("action-dismiss-lab")
    time.sleep(0.8)
    deadline = time.time() + (10 if case.get("settle") else 0)
    while time.time() < deadline:
        before = len(logged(run))
        run.trigger("wheel-state")
        time.sleep(0.2)
        states = [e for e in logged(run)[before:] if e.get("wheel") == "state"]
        if states and states[-1].get("holder") == "":
            return
