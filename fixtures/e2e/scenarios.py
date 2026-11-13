"""The end-to-end scenarios fixtures/e2e/run.py drives: native ones, then each web editor in each browser."""

# name, lab text, stub script, expectations (insert cases: the `insert` text and the `expect`ed outcome, see
# inserts.py). Selections are "location,length" in UTF-16 units.
# "{round}" in a text becomes the soak round, for drafts that must differ from the last round's.
SCENARIOS = [
    dict(
        name="fix-draft",
        text="teh docs need a smal update",
        stub={"answer": "the docs need a small update"},
        outcome="fixed",
        final="the docs need a small update",
    ),
    dict(
        name="fix-selection",
        text="keep thsi. fix teh second part",
        selection="11,19",
        stub={"answer": "fix the second part"},
        outcome="fixed",
        final="keep thsi. fix the second part",
    ),
    dict(
        name="multiline-unicode",
        text="Merci pour ton aide 🙏\nje vais regardé ça demain",
        stub={"answer": "Merci pour ton aide 🙏\nje vais regarder ça demain"},
        outcome="fixed",
        final="Merci pour ton aide 🙏\nje vais regarder ça demain",
    ),
    dict(name="edges-restored", text="  teh end  ", stub={"answer": "the end"}, outcome="fixed", final="  the end  "),
    dict(
        name="already-clear",
        text="All good here, round {round}.",
        stub={"answer": "All good here, round {round}."},
        outcome="clear",
    ),
    # The same draft again, same model and prompt: no need to ask.
    dict(
        name="already-clear-again",
        text="All good here, round {round}.",
        stub={"answer": "x"},
        outcome="skipped",
        no_model=True,
    ),
    dict(
        name="nothing-to-fix",
        text="@alice https://example.com/a 👍",
        stub={"answer": "x"},
        outcome="skipped",
        reason="Nothing to fix",
        no_model=True,
    ),
    dict(
        name="too-long",
        text="a" * 16_001,
        stub={"answer": "x"},
        outcome="failed",
        stage="capture",
        reason="tooLong",
        no_model=True,
    ),
    dict(
        name="restore",
        text="ths is a smal test",
        stub={"answer": "this is a small test"},
        outcome="fixed",
        final="this is a small test",
        restore=True,
    ),
    # Unsafe changes are dropped one by one; the rest of the answer still applies.
    dict(
        name="line-break-changed",
        text="line one\nline twoo",
        stub={"answer": "line one line two"},
        outcome="fixed",
        final="line one\nline two",
        dropped=1,
    ),
    dict(
        name="url-changed",
        text="see https://exmaple.com/a for teh docs",
        stub={"answer": "see https://example.com/a for the docs"},
        outcome="fixed",
        final="see https://exmaple.com/a for the docs",
        dropped=1,
    ),
    dict(
        name="only-unsafe-changes",
        text="see `cod` here",
        stub={"answer": "see `code` here"},
        outcome="failed",
        stage="provider",
    ),
    # Curly apostrophes the draft never used are typography, not fixes.
    dict(
        name="drift-absorbed",
        text="dont worry its fine",
        stub={"answer": "Don’t worry, it’s fine"},
        outcome="fixed",
        final="Don't worry, it's fine",
    ),
    dict(name="invalid-json", text="teh docs", stub={"raw": "not json"}, outcome="failed", stage="provider"),
    dict(
        name="offline", text="teh docs", stub={"fail": "offline"}, outcome="failed", stage="provider", reason="offline"
    ),
    dict(name="slow", text="teh docs", stub={"fail": "slow"}, outcome="failed", stage="provider", reason="slow"),
    dict(
        name="signed-out", text="teh docs", stub={"fail": "signIn"}, outcome="failed", stage="provider", reason="signIn"
    ),
    dict(name="limit", text="teh docs", stub={"fail": "limit"}, outcome="failed", stage="provider", reason="limit"),
    # Nothing to correct: capture refuses and no model is asked.
    dict(
        name="blank-draft", text="   ", stub={"answer": "x"}, outcome="skipped", reason="Nothing to fix", no_model=True
    ),
    # An editor that exposes no text: the selection is copied, corrected and pasted back over itself.
    dict(
        name="opaque-selection",
        scenario="e2e-opaque",
        text="keep this. fix teh second part",
        selection="11,19",
        stub={"answer": "fix the second part"},
        outcome="fixed",
        final="keep this. fix the second part",
        capture="copy",
    ),
    dict(
        name="opaque-no-selection",
        scenario="e2e-opaque",
        text="teh docs",
        stub={"answer": "the docs"},
        outcome="failed",
        stage="capture",
        no_model=True,
    ),
    dict(
        name="password-field",
        scenario="e2e-secure",
        stub={"answer": "x"},
        outcome="failed",
        stage="capture",
        no_model=True,
        final=None,
    ),
    # Typing while the model works: the swap refuses and the correction waits to be copied.
    dict(
        name="draft-changed",
        text="teh docs",
        stub={"answer": "the docs", "delayMs": 1500},
        append=" and more",
        outcome="pending",
        final="teh docs and more",
    ),
    # Each fix is its own paste: the mention between them is never pasted over, both ways.
    dict(
        name="mention-between-fixes",
        text="teh @alice smal",
        stub={"answer": "the @alice small"},
        outcome="fixed",
        final="the @alice small",
        restore=True,
    ),
]

# Fix text pressed again (D10). Each `then` step is one more press: `revert` and `reapply` are labels on the
# first attempt and never ask the stub; `attempt` is a new correction that does. Each case has its own text,
# so the one before it can't be taken for this one.
SCENARIOS += [
    dict(
        name="toggle:restore",
        text="pleese chek the numbrs",
        stub={"answer": "please check the numbers"},
        outcome="fixed",
        final="please check the numbers",
        then=[dict(expect="revert", text="pleese chek the numbrs")],
    ),
    # A clean toggle: restore, re-apply from memory, restore again.
    dict(
        name="toggle:reapply",
        text="lets meet tomorow mornig",
        stub={"answer": "let's meet tomorrow morning"},
        outcome="fixed",
        final="let's meet tomorrow morning",
        then=[
            dict(expect="revert", text="lets meet tomorow mornig"),
            dict(expect="reapply", text="let's meet tomorrow morning"),
            dict(expect="revert", text="lets meet tomorow mornig"),
        ],
    ),
    dict(
        name="toggle:typed",
        text="the reprot is redy",
        stub={"answer": "the report is ready"},
        outcome="fixed",
        final="the report is ready",
        then=[
            dict(
                append=" agian",
                stub={"answer": "the report is ready again"},
                expect="attempt",
                outcome="fixed",
                text="the report is ready again",
            )
        ],
    ),
    # Another field in the same window holding the very text the correction left: corrected, not restored.
    dict(
        name="toggle:other-field",
        text="thanks for teh revew",
        stub={"answer": "thanks for the review"},
        outcome="fixed",
        final="thanks for the review",
        then=[dict(other="thanks for the review", expect="attempt", outcome="clear", text="thanks for the review")],
    ),
]


# One case per failure class the reliability bake-off fixed (fixtures/bakeoff).
SCENARIOS += [
    # An input method composing at the caret: its marked text isn't the person's yet.
    dict(
        name="ime-composing",
        variant="ime",
        text="teh docs",
        stub={"answer": "x"},
        outcome="failed",
        stage="capture",
        no_model=True,
        final=None,
    ),
    # Attachment chips between fixes are kept, both ways.
    dict(
        name="chips-between-fixes",
        text="teh \ufffc smal \ufffc",
        stub={"answer": "the \ufffc small \ufffc"},
        outcome="fixed",
        final="the \ufffc small \ufffc",
        restore=True,
    ),
    # The app rebuilds its editor after each edit: Oops follows it, both ways.
    dict(
        name="remounted-editor",
        variant="remount",
        text="ths is a smal test",
        stub={"answer": "this is a small test"},
        outcome="fixed",
        final="this is a small test",
        restore=True,
    ),
    # An empty field may hide its text: the drop says to select it.
    dict(
        name="empty-field",
        text="",
        stub={"answer": "x"},
        outcome="skipped",
        reason="Nothing to fix. If your draft is there, select it first.",
        no_model=True,
    ),
    dict(
        name="webkit:readonly",
        host="webkit",
        scenario="web-readonly",
        text="keep thsi part",
        selection="0,14",
        stub={"answer": "x"},
        outcome="failed",
        stage="capture",
        no_model=True,
    ),
    # Text drawn elsewhere, edited through a hidden field that holds only the selection.
    dict(
        name="webkit:proxy-selection",
        host="webkit",
        scenario="web-proxy",
        text="keep this. fix teh second part",
        selection="11,19",
        stub={"answer": "fix the second part"},
        outcome="fixed",
        final="keep this. fix the second part",
        capture="copy",
    ),
    dict(
        name="webkit:proxy-no-selection",
        host="webkit",
        scenario="web-proxy",
        text="teh docs",
        stub={"answer": "x"},
        outcome="failed",
        stage="capture",
        no_model=True,
    ),
    # An editor that adopts a new selection late: each paste waits until a copy shows it took it.
    dict(
        name="webkit:own-selection",
        host="webkit",
        scenario="web-own-selection",
        text="teh docs need a smal update",
        stub={"answer": "the docs need a small update"},
        outcome="fixed",
        final="the docs need a small update",
        restore=True,
    ),
    # An inline image Chromium counts in its ranges but not its value.
    dict(
        name="chrome:image-between-fixes",
        host="chrome",
        scenario="web-image",
        text="teh \ufffc smal fix",
        stub={"answer": "the \ufffc small fix", "delayMs": 2500},
        outcome="fixed",
        final="the \ufffc small fix",
    ),
    # Right-to-left text with a Latin mention in a combobox: Chromium reads it in display order, while its
    # selection counts as typed. The fix at the very end makes its stale value the only one to differ.
    dict(
        name="chrome:rtl-combobox",
        host="chrome",
        scenario="web-rtl-combobox",
        text="اترك هاذا الجزء كما هو. ثم صحح الجزء التاني @Alice Martin من الخطه",
        selection="24,42",
        stub={"answer": "ثم صحح الجزء الثاني @Alice Martin من الخطة", "delayMs": 2500},
        outcome="fixed",
        final="اترك هاذا الجزء كما هو. ثم صحح الجزء الثاني @Alice Martin من الخطة",
        restore=True,
    ),
    # A textarea can acknowledge document marker writes while keeping its own input selection.
    dict(
        name="zen:rtl-textarea-selection",
        host="zen",
        scenario="web-textarea",
        text="اترك هاذا الجزء كما هو. ثم صحح الجزء التاني @Alice Martin من الخطه",
        selection="24,42",
        stub={"answer": "ثم صحح الجزء الثاني @Alice Martin من الخطة"},
        outcome="fixed",
        final="اترك هاذا الجزء كما هو. ثم صحح الجزء الثاني @Alice Martin من الخطة",
        restore=True,
    ),
    # Gecko's character ranges omit blank blocks; a word at a paragraph start must not take one with it.
    dict(
        name="zen:paragraph-start",
        host="zen",
        scenario="web-paragraphs",
        text="hello team\n\nteh docs need a smal update\n\nthanks",
        stub={"answer": "hello team\nthe docs need a small update\nthanks"},
        outcome="fixed",
        final="hello team\n\nthe docs need a small update\n\nthanks",
        restore=True,
    ),
    dict(
        name="zen:rtl-paragraph-combobox",
        host="zen",
        scenario="web-paragraph-combobox",
        text="مرحبا بالفريق\n\nتحديت سريع عن الخطة\n\nتم نقل المراجعه إلى الخميس",
        stub={"answer": "مرحبا بالفريق تحديث سريع عن الخطة تم نقل المراجعة إلى الخميس"},
        outcome="fixed",
        final="مرحبا بالفريق\n\nتحديث سريع عن الخطة\n\nتم نقل المراجعة إلى الخميس",
        restore=True,
    ),
]

# Insert at the caret: no correction runs, so there is no stub. Each case checks the outcome Oops logs, the
# text left behind and that the clipboard is back as it was.
INSERTS = [
    dict(name="insert-empty", text="", insert="hello there", expect="inserted", final="hello there"),
    # A field showing only its placeholder reads as empty.
    dict(
        name="insert-placeholder",
        variant="placeholder",
        text="",
        insert="hello there",
        expect="inserted",
        final="hello there",
    ),
    dict(
        name="insert-caret",
        text="send the notes today",
        selection="9,0",
        insert="release ",
        expect="inserted",
        final="send the release notes today",
    ),
    dict(
        name="insert-selection",
        text="send the notes today",
        selection="9,5",
        insert="minutes",
        expect="inserted",
        final="send the minutes today",
    ),
    dict(
        name="insert-unicode",
        text="Merci",
        insert=" beaucoup 🙏\nà demain",
        expect="inserted",
        final="Merci beaucoup 🙏\nà demain",
    ),
    # Hex's spacing: one space after a word, none before punctuation.
    dict(
        name="insert-after-word",
        text="Hello",
        selection="5,0",
        insert="there",
        expect="inserted",
        final="Hello there",
    ),
    dict(
        name="insert-before-punctuation",
        text="Hello",
        selection="5,0",
        insert=", world.",
        expect="inserted",
        final="Hello, world.",
    ),
    # The field's text must stay as it was.
    dict(name="insert-secure", scenario="e2e-secure", insert="hunter3", expect="refused", reason="secureField"),
]
WEB_INSERTS = [
    "insert-empty",
    "insert-placeholder",
    "insert-caret",
    "insert-selection",
    "insert-after-word",
    "insert-before-punctuation",
]
SCENARIOS += INSERTS + [
    dict(c, name=f"webkit:textarea:{c['name']}", host="webkit", scenario="web-textarea")
    for c in INSERTS
    if c["name"] in WEB_INSERTS
]

# The editors fixtures/e2e/web.html offers, and the cases each runs, by native scenario name.
WEB_EDITORS = ["contenteditable", "textarea", "document", "design"]
WEB_CASES = ["fix-draft", "fix-selection", "multiline-unicode", "restore", "mention-between-fixes", "draft-changed"]
WEB_HOSTS = ["webkit", "chrome", "zen"]
SCENARIOS += [
    dict(
        next(c for c in SCENARIOS if c["name"] == case),
        name=f"{host}:{editor}:{case}",
        host=host,
        scenario=f"web-{editor}",
    )
    for host in WEB_HOSTS
    for editor in WEB_EDITORS
    for case in WEB_CASES
]

# The default run: every native case, WebKit's composer and textarea, and the bake-off classes above.
# `--full` adds every web case in Chrome and Zen.
QUICK = [
    c["name"]
    for c in SCENARIOS
    if "host" not in c
    or c["name"].split(":")[1] not in WEB_EDITORS
    or c["host"] == "webkit"
    and c["name"].split(":")[1] in ("contenteditable", "textarea")
]
