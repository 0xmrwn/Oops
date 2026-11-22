"""Typed-centre cases for fixtures/e2e/run.py, checked by wheel.py: typing in the Actions wheel's centre turns it into
a field, whose first character never reaches the draft, and Return runs what was typed."""

from wheel import CARDINAL, OPEN

SELECTION = dict(text="keep this. make this second part much shorter please", selection="11,41")

TYPED = [
    dict(
        name="wheel:typed",
        **CARDINAL,
        steps=OPEN + [("type", "make it formal"), ("wait", 300), ("key", "return", "tap")],
        outcomes=["written"],
        seen=["beginTyping=Type an instruction", "run=typed/make it formal"],
        final="let's meet next week",
        calls=1,
        instructions="make it formal",
    ),
    # The key that opens the field is its first character, never the draft's.
    dict(
        name="wheel:typed-first-key",
        text="keep me",
        stub={"answer": "x"},
        steps=OPEN + [("type", "x"), ("wait", 400), ("state",)],
        outcomes=[],
        state={"level": "typing", "fieldText": "x", "fieldKey": "yes"},
        unseen=["run", "typing-failed"],
        calls=0,
    ),
    dict(
        name="wheel:typed-value",
        text="good morning",
        stub={"answer": "nuqneH"},
        steps=OPEN
        + [("key", "right", "tap"), ("wait", 300), ("type", "Klingon"), ("wait", 300), ("key", "return", "tap")],
        outcomes=["written"],
        seen=["select=right", "beginTyping=Language", "run=Translate/Klingon"],
        final="nuqneH",
        calls=1,
    ),
    # Escape gives the keys back to the lab, which stays in front, its draft untouched.
    dict(
        name="wheel:typed-escape",
        text="keep me",
        stub={"answer": "x"},
        steps=OPEN + [("type", "abc"), ("wait", 300), ("key", "escape", "tap"), ("wait", 800), ("state",)],
        outcomes=[],
        unseen=["run"],
        state={"open": "no", "frontmost": "dev.0xmrwn.oops-native-lab"},
        calls=0,
    ),
    # Return on an empty field does nothing.
    dict(
        name="wheel:typed-empty",
        text="keep me",
        stub={"answer": "x"},
        steps=OPEN + [("key", "return", "tap"), ("wait", 400), ("key", "return", "tap"), ("wait", 300), ("state",)],
        outcomes=[],
        seen=["beginTyping=Type an instruction"],
        unseen=["run"],
        state={"level": "typing", "open": "yes"},
        calls=0,
    ),
    # What was typed runs on the selection the field had, which Oops gave back before running.
    dict(
        name="wheel:typed-selection",
        **SELECTION,
        stub={"answer": "shorter second part"},
        steps=OPEN + [("type", "shorter"), ("wait", 300), ("key", "return", "tap")],
        outcomes=["written"],
        seen=["run=typed/shorter"],
        final="keep this. shorter second part",
        calls=1,
    ),
    # Where the centre can't type, a letter is taken and does nothing; the arrows still run.
    dict(
        name="wheel:typing-unavailable",
        **CARDINAL,
        library={"typing": False},
        steps=OPEN + [("type", "a"), ("wait", 300), ("key", "down", "tap")],
        outcomes=["written"],
        seen=["key=yes", "run=Shorten"],
        unseen=["beginTyping"],
        final="let's meet next week",
        calls=1,
    ),
]

# The same in the browsers' text areas: WebKit (the native lab's web view) in the quick set, Chrome in --full. The
# lab's own app is not in front there.
TYPED += [
    dict(
        base,
        name=f"{host}:textarea:wheel-{base['name'].split(':')[1]}",
        host=host,
        scenario="web-textarea",
        state={k: v for k, v in base.get("state", {}).items() if k != "frontmost"},
    )
    for host in ("webkit", "chrome")
    for base in [c for c in TYPED if c["name"] in ("wheel:typed", "wheel:typed-value", "wheel:typed-escape")]
]
