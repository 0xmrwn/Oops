"""Agent cases for fixtures/e2e/run.py: a starter action run as an agent on the lab's draft by the `agent-lab` trigger,
with the stub agent (`-StubAgent`) streaming the case's steps and answering, so no Claude Code or model runs. Oops logs
every change of the run (phase, field, step, menu mark, and the drop's owner, phase and label) in agent.jsonl, and how
each run ended in actions.jsonl: a ready result ends once it is written, held to copy or dismissed.

A case's `steps` say what happens while it runs: ("wait", ms), ("away",) to bring Finder to the front, ("other", text)
to move to a second field in the lab, ("append", text) to type into the run's field, ("fix", text) to run Fix there,
("model", action) to run a model action there, ("again",) to start a second agent run, ("until", field, value) to wait
for an agent.jsonl line, ("back", field, value) to bring the lab and its field back and ("key", name, field, value) to
press Return or Escape (posted at the HID level by `agent-key`), each then waiting for a line logged after it, and
("act",), ("dismiss",), ("cancel",) for the
menu's items. Expectations: `outcome` of the run (`reason` when it failed), `seen` labels of the run's drop in order,
`last` fields of the last agent.jsonl line, `final` text of the lab field, `ended` as the stub wrote it, and the stub's
`calls`."""

import json
import subprocess
import time
from pathlib import Path

import actions

TRIGGER = Path(__file__).resolve().parents[2] / ".build/lab-tools/trigger"

ANSWER = "Here is the summary you asked for."
SEARCH_READ = [{"search": "q"}, {"read": "https://example.com/x"}]
BASE = dict(text="summarise the thread for me", action="Shorten")

AGENT = [
    # The person stays: the status follows each step at the caret, and the answer is written like a slow Fix. Steps
    # come further apart than a label holds (1.5 s), or the later one would stand in for the earlier.
    dict(
        BASE,
        name="agent:in-field",
        stub={
            "steps": SEARCH_READ,
            "stepMs": 1600,
            "delayMs": 1600,
            "activityMs": 300,
            "summary": "Cut it to one line",
            "answer": ANSWER,
        },
        outcome="written",
        seen=["Searching “q”", "Reading example.com", "Putting it in place"],
        last={"phase": "idle", "mark": "none", "drop": "agent", "dropPhase": "fixed"},
        final=ANSWER,
        ended="finished",
    ),
    # Away when it ends: the drop has parked at the screen's edge, nothing is written, the result waits ready in the
    # pill, and acting on it goes back and writes it.
    dict(
        BASE,
        name="agent:away-ready-act",
        stub={"steps": SEARCH_READ, "stepMs": 1500, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("away",),
            ("until", "mark", "ready"),
            ("act",),
            ("until", "phase", "idle"),
        ],
        outcome="written",
        away={"parked": True},
        ready={"label": "Shorten is ready", "dropPhase": "fixed", "parked": "yes"},
        last={"mark": "none", "drop": "agent", "dropPhase": "fixed"},
        final=ANSWER,
        ended="finished",
    ),
    # Away a while, the drop parks; back in the field while it runs, it flies back and the answer is written in place.
    dict(
        BASE,
        name="agent:away-park-back",
        stub={"steps": SEARCH_READ, "stepMs": 3000, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("away",),
            ("until", "parked", "yes"),
            ("back", "parked", "no"),
        ],
        outcome="written",
        away={"parked": True},
        last={"phase": "idle", "mark": "none", "drop": "agent", "dropPhase": "fixed", "parked": "no"},
        final=ANSWER,
        ended="finished",
    ),
    # Finished while away, then back in the field on their own: the ready drop waits at the caret, and Return puts it in.
    dict(
        BASE,
        name="agent:ready-back-return",
        stub={"steps": SEARCH_READ, "stepMs": 1500, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("away",),
            ("until", "mark", "ready"),
            ("back", "confirm", "yes"),
            ("key", "return", "phase", "idle"),
        ],
        outcome="written",
        ready={"label": "Shorten is ready · Return puts it in", "dropPhase": "fixed", "parked": "no"},
        last={"phase": "idle", "mark": "none", "drop": "agent", "dropPhase": "fixed", "confirm": "no"},
        final=ANSWER,
        ended="finished",
    ),
    # Escape sends the ready drop back to the pill, and Return is the field's again.
    dict(
        BASE,
        name="agent:ready-back-escape",
        stub={"steps": SEARCH_READ, "stepMs": 1500, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("away",),
            ("until", "mark", "ready"),
            ("back", "confirm", "yes"),
            ("key", "escape", "parked", "yes"),
            ("dismiss",),
        ],
        outcome="cancelled",
        last={"phase": "idle", "mark": "none", "confirm": "no"},
        final=BASE["text"],
        ended="finished",
    ),
    # Back in the field, the person types instead: the draft changed, so the drop offers the answer to copy.
    dict(
        BASE,
        name="agent:ready-back-typed",
        stub={"steps": SEARCH_READ, "stepMs": 1500, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("away",),
            ("until", "mark", "ready"),
            ("back", "confirm", "yes"),
            ("append", " please"),
            # Return right after typing is the field's: the draft no longer reads as it was read.
            ("key", "return"),
            ("until", "dropPhase", "pending"),
        ],
        outcome="held",
        last={"phase": "idle", "mark": "none", "dropPhase": "pending", "label": "Not written", "confirm": "no"},
        final="summarise the thread for me please\n",
        ended="finished",
    ),
    # Back in the field, then straight into another field in the same window: Return is that field's, and the answer
    # stays ready.
    dict(
        BASE,
        name="agent:ready-back-other-field",
        stub={"steps": SEARCH_READ, "stepMs": 1500, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("away",),
            ("until", "mark", "ready"),
            ("back", "confirm", "yes"),
            ("other", "a second draft"),
            ("key", "return"),
            ("state",),
            ("dismiss",),
        ],
        outcome="cancelled",
        state={"phase": "ready", "mark": "ready"},
        last={"phase": "idle", "mark": "none", "confirm": "no"},
        final="a second draft\n",
        ended="finished",
    ),
    # The draft changed while the run was away: acting on it writes nothing and offers the answer to copy.
    dict(
        BASE,
        name="agent:away-changed-copy",
        stub={"steps": SEARCH_READ, "stepMs": 1500, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("away",),
            ("append", " please"),
            ("until", "mark", "ready"),
            ("act",),
            ("until", "phase", "idle"),
        ],
        outcome="held",
        last={"mark": "none", "dropPhase": "pending", "label": "Not written"},
        final="summarise the thread for me please",
        ended="finished",
    ),
    # Another field in the lab: the drop lets go, Fix runs there, and the result is held ready.
    dict(
        BASE,
        name="agent:leave-field-fix",
        stub={"steps": SEARCH_READ, "stepMs": 2000, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("other", "thanks for teh revew"),
            ("until", "inField", "no"),
            ("fix", "thanks for the review"),
            ("until", "mark", "ready"),
            ("dismiss",),
        ],
        outcome="cancelled",
        last={"phase": "idle", "mark": "none"},
        ended="finished",
    ),
    dict(
        BASE,
        name="agent:cancel-menu",
        stub={"steps": SEARCH_READ, "stepMs": 2000, "answer": ANSWER},
        steps=[("until", "step", "Searching “q”"), ("away",), ("cancel",)],
        outcome="cancelled",
        last={"phase": "idle", "mark": "none"},
        final=BASE["text"],
        ended="cancelled",
    ),
    # In the field the drop's tap, Escape and the menu's Cancel all end the run the same way.
    dict(
        BASE,
        name="agent:cancel-field",
        stub={"steps": SEARCH_READ, "stepMs": 2000, "answer": ANSWER},
        steps=[("until", "step", "Searching “q”"), ("state",), ("cancel",)],
        outcome="cancelled",
        state={"escape": "yes", "drop": "agent", "dropPhase": "working"},
        last={"phase": "idle", "mark": "none", "drop": "none"},
        final=BASE["text"],
        ended="cancelled",
    ),
    dict(
        BASE,
        name="agent:second-refused",
        stub={"steps": SEARCH_READ, "stepMs": 2000, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("other", "a second draft"),
            ("until", "inField", "no"),
            ("again",),
            ("cancel",),
        ],
        outcome="cancelled",
        refused="agentBusy",
        calls=1,
        ended="cancelled",
    ),
    dict(
        BASE,
        name="agent:model-meanwhile",
        stub={"steps": SEARCH_READ, "stepMs": 2000, "answer": ANSWER},
        steps=[
            ("until", "step", "Searching “q”"),
            ("other", "a second draft that is too long"),
            ("until", "inField", "no"),
            ("model", "short second draft"),
            ("cancel",),
        ],
        outcome="cancelled",
        final="short second draft",
        ended="cancelled",
    ),
    dict(
        BASE,
        name="agent:timeout",
        stub={"steps": [{"think": True}], "stepMs": 200, "delayMs": 5000, "limitMs": 600, "answer": ANSWER},
        outcome="failed",
        reason="slow",
        last={"phase": "idle", "mark": "none", "dropPhase": "failed"},
        final=BASE["text"],
        ended="timedOut",
    ),
    dict(
        BASE,
        name="agent:dismiss",
        stub={"steps": SEARCH_READ, "stepMs": 1500, "answer": ANSWER},
        steps=[("until", "step", "Searching “q”"), ("away",), ("until", "mark", "ready"), ("dismiss",)],
        outcome="cancelled",
        last={"phase": "idle", "mark": "none", "drop": "none"},
        final=BASE["text"],
        ended="finished",
    ),
    # Nothing runs without Claude Code, or without the sandbox.
    dict(
        BASE,
        name="agent:not-installed",
        stub={"unavailable": "notInstalled"},
        outcome="failed",
        reason="setup",
        calls=0,
    ),
    dict(
        BASE, name="agent:no-sandbox", stub={"fail": "sandbox"}, outcome="failed", reason="sandbox", final=BASE["text"]
    ),
]


def logged(run):
    try:
        return [json.loads(line) for line in (run.log / "agent.jsonl").read_text().splitlines() if line.strip()]
    except OSError:
        return []


def post(name, *arguments):
    """A trigger that acts wherever focus is, as the menu's items do: the lab is not brought forward first."""
    subprocess.run([str(TRIGGER), name, *arguments], check=True)


def stub_file(run, suffix):
    try:
        return (run.work / f"agent.json.{suffix}").read_text()
    except OSError:
        return None


def step(run, case, action, before):
    kind = action[0]
    if kind == "wait":
        time.sleep(action[1] / 1000)
    elif kind == "away":
        subprocess.run(["osascript", "-e", 'tell application "Finder" to activate'], check=True)
        time.sleep(0.6)
    elif kind in ("other", "append"):
        run.control(case.get("scenario", "e2e"), **{kind: action[1]})
        time.sleep(0.4)
    elif kind == "until":
        _, field, value = action
        run.wait(lambda: any(e.get(field) == value for e in logged(run)[before:]), 20, f"agent {field} never {value}")
    elif kind == "fix":
        attempts = len([e for e in run.entries() if e["kind"] == "attempt"])
        run.write(run.stub, {"answer": action[1]})
        run.trigger("correct-lab")
        run.wait(lambda: len([e for e in run.entries() if e["kind"] == "attempt"]) > attempts, 20, "Fix never ran")
    elif kind == "model":
        done = len(actions.logged(run))
        run.write(run.stub, {"answer": action[1]})
        run.trigger("action-lab", "Shorten")
        run.wait(lambda: len(actions.logged(run)) > done, 20, "the model action never ended")
    elif kind == "again":
        done = len(actions.logged(run))
        run.trigger("agent-lab", case["action"])
        run.wait(lambda: len(actions.logged(run)) > done, 10, "the second run was never logged")
    elif kind == "key" and len(action) == 2:
        # A key that should reach the field: nothing to wait for but the field.
        post("agent-key", action[1])
        time.sleep(0.6)
    elif kind in ("back", "key"):
        # Waits for a line logged after it acts: the same value may have been logged before.
        *_, field, value = action
        count = len(logged(run))
        if kind == "back":
            run.trigger("agent-state")
        else:
            # Oops posts it at the HID level, where the ready drop's tap and the field in front meet it as a person's.
            post("agent-key", action[1])
        run.wait(
            lambda: any(e.get(field) == value for e in logged(run)[count:]),
            20,
            f"agent {field} never {value} after {kind}",
        )
    elif kind == "state":
        count = len(logged(run))
        post("agent-state")
        run.wait(lambda: len(logged(run)) > count, 5, "no agent state")
    else:
        post("agent-" + kind)
        time.sleep(0.6)


def check(run, case):
    """Runs the case's agent action on its field, takes its steps, and returns the problems found."""
    agent_stub = run.work / "agent.json"
    run.write(agent_stub, case["stub"])
    for suffix in ("calls", "ended"):
        (run.work / f"agent.json.{suffix}").unlink(missing_ok=True)
    run.show(case.get("scenario", "e2e"), case.get("text"))
    before, done = len(logged(run)), len(actions.logged(run))
    run.trigger("agent-lab", case["action"])
    for action in case.get("steps", []):
        step(run, case, action, before)
    # Steps that start runs of their own log them first: the agent run's outcome is the last one.
    others = len([a for a in case.get("steps", []) if a[0] in ("model", "again")])
    entry = run.wait(lambda: actions.logged(run)[done:][others:], 30, "no agent run was logged")[-1]
    run.wait(lambda: logged(run)[before:] and logged(run)[-1].get("phase") == "idle", 20, "the run never went idle")
    time.sleep(0.6)
    lines = logged(run)[before:]
    final = case.get("final")
    found = [("outcome", entry.get("outcome"), case["outcome"]), ("reason", entry.get("reason"), case.get("reason"))]
    labels = [e.get("label") for e in lines if e.get("drop") == "agent" and e.get("dropPhase") == "working"]
    seen = [label for label in case.get("seen", []) if label in labels]
    # A label stays up while other things are logged: each counts once each time it comes up.
    shown = [label for i, label in enumerate(labels) if label in seen and (i == 0 or labels[i - 1] != label)]
    found.append(("seen in order", shown, case.get("seen", [])))
    for field, wanted in case.get("last", {}).items():
        found.append((f"last {field}", lines[-1].get(field) if lines else None, wanted))
    if "away" in case:
        away = [e for e in lines if e.get("inField") == "no" and e.get("mark") == "running"]
        found.append(("parked while away", any(e.get("parked") == "yes" for e in away), case["away"]["parked"]))
    if "ready" in case:
        ready = [e for e in lines if e.get("mark") == "ready" and e.get("drop") == "agent"]
        found.append(("ready drop", ready and {k: ready[-1].get(k) for k in case["ready"]}, case["ready"]))
    if "state" in case:
        states = [e for e in lines if "escape" in e]
        found.append(("state", states and {k: states[-1].get(k) for k in case["state"]}, case["state"]))
    if "refused" in case:
        found.append(("refused", [e.get("reason") for e in actions.logged(run)[done:]].count(case["refused"]), 1))
    if final is not None:
        found.append(("text", run.state().get("text"), final))
    if "ended" in case:
        found.append(("ended", stub_file(run, "ended"), case["ended"]))
    found.append(("calls", int(stub_file(run, "calls") or 0), case.get("calls", 1)))
    run.trigger("action-dismiss-lab")
    return [f"{label}: wanted {wanted!r}, got {actual!r}" for label, actual, wanted in found if actual != wanted]
