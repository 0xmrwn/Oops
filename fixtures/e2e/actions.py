"""Action cases for fixtures/e2e/run.py: a saved action run on the lab's draft by the `action-lab` trigger (the
stub answers for its model), and its restore. Oops logs each outcome, with the drop's phase, in actions.jsonl."""

import json
import time

import inserts

# An action rewrites: its answer is pasted over the whole span in one go, at any length. Written word by word, a
# rewrite this size runs out the swap guard's 2 seconds and is put back.
LONG_ANSWER = "\n\n".join(
    " ".join(
        f"Paragraph {p} sentence {s} says the launch moves to Thursday so the team can finish the review."
        for s in range(1, 9)
    )
    for p in range(1, 9)
)
LONG_DRAFT = "\n".join(f"line {n} of the old plan needs another pass before we send it" for n in range(1, 41))
LONG_REWRITE = "\n".join(f"Step {n}: the new plan is ready to send" for n in range(1, 41))

ACTIONS = [
    # The whole draft, its mention and code included: none of Fix's checks apply to an action's answer.
    dict(
        name="action:whole-draft",
        text="ask @alice to check the `deploy` script today",
        action="Translate",
        value="French",
        stub={"answer": "demande à Alice de vérifier le script de déploiement aujourd’hui"},
        outcome="written",
        drop="fixed",
        final="demande à Alice de vérifier le script de déploiement aujourd’hui",
    ),
    # The selection only; the text around it stays as it was.
    dict(
        name="action:selection",
        text="keep this. make this second part much shorter please",
        selection="11,41",
        action="Shorten",
        stub={"answer": "shorter second part"},
        outcome="written",
        drop="fixed",
        final="keep this. shorter second part",
    ),
    # Typing while the model works: nothing is written, and the drop holds the answer to copy.
    dict(
        name="action:draft-changed",
        text="the plan for next week",
        action="Shorten",
        stub={"answer": "next week's plan", "delayMs": 1500},
        append=" and more",
        outcome="held",
        drop="pending",
        final="the plan for next week and more",
    ),
    # The restore runs while the result drop is up: it lives only as long as that drop.
    dict(
        name="action:restore",
        text="we should probably meet sometime next week to talk",
        action="Shorten",
        stub={"answer": "let's meet next week"},
        outcome="written",
        drop="fixed",
        final="let's meet next week",
        restore=True,
    ),
    # Ten words become about a thousand, then the original comes back the same way.
    dict(
        name="action:long-answer",
        text="tell the team the launch moves to thursday for the review",
        action="Shorten",
        stub={"answer": LONG_ANSWER},
        outcome="written",
        drop="fixed",
        final=LONG_ANSWER,
        restore=True,
    ),
    # Forty lines, every one rewritten.
    dict(
        name="action:long-rewrite",
        text=LONG_DRAFT,
        action="Shorten",
        stub={"answer": LONG_REWRITE},
        outcome="written",
        drop="fixed",
        final=LONG_REWRITE,
        restore=True,
    ),
    dict(
        name="action:failure",
        text="the plan for next week",
        action="Shorten",
        stub={"fail": "offline"},
        outcome="failed",
        reason="offline",
        drop="failed",
    ),
]


def logged(run):
    try:
        return [json.loads(line) for line in (run.log / "actions.jsonl").read_text().splitlines() if line.strip()]
    except OSError:
        return []


def check(run, case):
    """Runs the case's action on its field and returns the problems found: the outcome and drop Oops logged, the
    field's text, one model call, no Fix attempt, the clipboard as it was, and for `restore` the original back."""
    run.write(run.stub, case["stub"])
    run.show(case.get("scenario", "e2e"), case.get("text"), case.get("selection"), case.get("variant"))
    before, calls, copied = len(logged(run)), run.calls(), inserts.clipboard()
    attempts = len([e for e in run.entries() if e["kind"] == "attempt"])
    run.trigger("action-lab", case["action"], case.get("value", ""))
    if "append" in case:
        # The stub counts its call once the draft is captured, so the edit lands after the capture.
        run.wait(lambda: run.calls() > calls, 10, "the model was never asked")
        run.control(case.get("scenario", "e2e"), append=case["append"])
    entry = run.wait(lambda: logged(run)[before:], 20, "no action was logged")[0]
    final = case.get("final", case.get("text"))
    # The result drop, and with it the restore, lasts General's Show results for (5 s here, set at launch): look at
    # the text as soon as it lands.
    try:
        run.wait(lambda: run.state().get("text") == final, 2, "text")
    except TimeoutError:
        pass
    found = [
        ("outcome", entry.get("outcome"), case["outcome"]),
        ("reason", entry.get("reason"), case.get("reason")),
        ("drop", entry.get("drop"), case["drop"]),
        ("text", run.state().get("text"), final),
        ("stub calls", run.calls() - calls, 1),
        ("Fix attempts", len([e for e in run.entries() if e["kind"] == "attempt"]), attempts),
    ]
    if case.get("restore") and all(actual == wanted for _, actual, wanted in found):
        before = len(logged(run))
        run.trigger("action-restore-lab")
        restored = run.wait(lambda: logged(run)[before:], 10, "no restore was logged")[0]
        time.sleep(0.4)
        found += [
            ("restore", restored.get("outcome"), "restored"),
            ("restore drop", restored.get("drop"), "reverted"),
            ("restored text", run.state().get("text"), case["text"]),
        ]
    run.trigger("action-dismiss-lab")
    # Oops gives the clipboard back half a second after the swap. Its contents are never printed.
    time.sleep(0.8)
    problems = [f"{label}: wanted {wanted!r}, got {actual!r}" for label, actual, wanted in found if actual != wanted]
    if inserts.clipboard() != copied:
        problems.append("clipboard: not what it held before the action")
    return problems
