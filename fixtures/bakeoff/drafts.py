"""Each case's draft and what Oops should do with it.

A draft carries two typos where the correction applies (and, for a selection, one outside it that
must stay), an atom between the typos when the case has mentions or emoji images, and a "/" at the
caret when a slash menu is open. Right-to-left cases use Arabic drafts. The runner builds the stub
model's answer from what Oops captured, fixing only these typos.
"""

ATOMS = {"mentions": {"mention": "Alice Martin"}, "emoji-images": {"emoji": "🎉"}}
SINGLE_LINE = {
    "input",
    "password",
    "appkit-field",
    "catalyst-field",
    "appkit-secure",
    "catalyst-secure",
    "qt-secure",
    "swing-secure",
}

# A case's `span` (UTF-16 offsets), when it has one, is the part of the draft Oops should read and fix:
# the selection, or a block editor's focused paragraph. Without one it is the whole draft.
# target -> (paragraphs with "{atom}" where the atom goes, typos to fix, text the selection starts at,
# index of the paragraph the caret ends, or None for the end of the draft)
ENGLISH = {
    "whole": (
        ["hey, i just pushed teh fix {atom} for the login bug, it shoud work now"],
        {"teh": "the", "shoud": "should"},
        None,
        None,
    ),
    "selection": (
        ["keep thsi part as is. then fix teh second {atom} part, it is a smal change"],
        {"teh": "the", "smal": "small"},
        "then",
        None,
    ),
    "multiline": (
        [
            "Hi team,",
            "",
            "Quick update on teh planning {atom} for next week.",
            "",
            "The review moved to thursday, plese have your slides ready.",
        ],
        {"teh": "the", "plese": "please"},
        None,
        2,
    ),
}
ARABIC = {
    "whole": (
        ["مرحبا بالفريق، تم تحديت الخطة {atom} واصبحت الأولويات واضحة الآن"],
        {"تحديت": "تحديث", "واصبحت": "وأصبحت"},
        None,
        None,
    ),
    "selection": (
        ["اترك هاذا الجزء كما هو. ثم صحح الجزء التاني {atom} من الخطه"],
        {"التاني": "الثاني", "الخطه": "الخطة"},
        "ثم",
        None,
    ),
    "multiline": (
        ["مرحبا بالفريق،", "", "تحديت سريع عن خطة {atom} الأسبوع القادم.", "", "تم نقل المراجعه إلى يوم الخميس."],
        {"تحديت": "تحديث", "المراجعه": "المراجعة"},
        None,
        2,
    ),
}


def units(text):
    """Length in UTF-16 units, as every editor and toolkit counts offsets (an emoji like 🎉 is two)."""
    return len(text.encode("utf-16-le")) // 2


def at(text, offset):
    """The Python index of a UTF-16 offset into `text`."""
    count = 0
    for index, character in enumerate(text):
        if count >= offset:
            return index
        count += units(character)
    return len(text)


def label(segment):
    return "@" + segment["mention"] if "mention" in segment else segment.get("emoji") or segment["text"]


def draft(case):
    target = case["target"]
    paragraphs, typos, select_from, caret_paragraph = (ARABIC if case["presentation"] == "rtl" else ENGLISH)[target]
    atom = ATOMS.get(case["content"])
    segments = []
    for line in paragraphs:
        if "{atom}" not in line:
            segments.append([{"text": line}] if line else [])
        elif atom:
            before, after = line.split(" {atom} ")
            segments.append([{"text": before + " "}, dict(atom), {"text": " " + after}])
        else:
            segments.append([{"text": line.replace(" {atom} ", " ")}])
    lines = ["".join(label(s) for s in p) for p in segments]
    if case.get("reaction") == "slash-menu":
        paragraph = len(lines) - 1 if caret_paragraph is None else caret_paragraph
        segments[paragraph] = segments[paragraph] + [{"text": " /"}]
        lines[paragraph] += " /"
    text = "\n".join(lines)
    result = {"draft": {"paragraphs": segments}, "text": text, "typos": typos}
    editor = case.get("engine") or case.get("toolkit")
    if case.get("reaction") == "ime" and editor in IME_UNSEEN | IME_HARMFUL:
        # The composition the shell starts at the caret, and whether the field's text includes it: what the
        # person sees, against which a correction during it is graded.
        result["composed"] = {
            "text": COMPOSED,
            "inText": editor in COMPOSITION_IN_TEXT,
            "inCapture": editor in COMPOSITION_IN_CAPTURE,
        }
    if select_from:
        result["selection"] = [units(text[: text.index(select_from)]), units(text)]
    else:
        paragraph = len(lines) - 1 if caret_paragraph is None else caret_paragraph
        start = sum(units(line) + 1 for line in lines[:paragraph])
        result["caret"] = start + units(lines[paragraph])
        # In a block editor the draft is the focused block: the caret's paragraph is what Oops should read.
        if case.get("engine") == "blocks":
            result["span"] = [start, result["caret"]]
    return result


# IME by mechanism, from the fixer's observation run: editors not listed here show the composition to
# Accessibility (a marked range or marked text-marker range), so Oops should refuse. These don't.
COMPOSED = "にほんご"  # what every shell's IME leaves at the caret
IME_UNSEEN = {"appkit-field", "swiftui-field", "trix", "qt"}  # unseen, and a correction lands cleanly
IME_HARMFUL = {"catalyst-textview", "catalyst-field"}  # unseen, and the paste replaces the composition
COMPOSITION_IN_TEXT = {"appkit-field", "swiftui-field", "trix"}  # graded as committed in the editor's text
COMPOSITION_IN_CAPTURE = (IME_UNSEEN | IME_HARMFUL) - {
    "qt"
}  # Accessibility reads it; Qt's value leaves the preedit out

WORKS = ["capture", "apply", "revert", "highlight", "placement"]
COPY = ["capture", "apply", "placement"]
REFUSES = ["refused", "untouched", "message"]


def expectation(case):
    editor = case.get("engine") or case.get("toolkit")
    selected = case["target"] == "selection"
    if editor in ("password", "appkit-secure", "catalyst-secure", "qt-secure", "swing-secure"):
        return {
            "result": "refuses",
            "stages": REFUSES,
            "message": "password|secure",
            "why": "A password field: Oops never reads secrets, and says it doesn't read password fields.",
        }
    if editor in ("readonly", "appkit-readonly"):
        return {
            "result": "refuses",
            "stages": REFUSES,
            "message": "edit|read-only|editable",
            "why": "Selected text in a read-only document: there is no draft to correct, and pasting would do nothing.",
        }
    # A view that draws its own text shows Accessibility only a group: no text, and no marked range, so no
    # client can tell a composition is in progress there. It is graded like any other selection or none.
    if editor in ("canvas", "custom-opaque"):
        if selected:
            return {
                "result": "works",
                "stages": COPY,
                "message": None,
                "why": "The editor draws its text and exposes none, but copy and paste work on a selection: Oops corrects "
                "the selection through the clipboard. Nothing can confirm the result, so no revert or flash, by design.",
            }
        return {
            "result": "refuses",
            "stages": REFUSES,
            "message": "[Ss]elect",
            "why": "The editor exposes no text and nothing is selected: Oops can't read the draft, and should ask for a selection.",
        }
    if case.get("reaction") == "ime" and editor in IME_HARMFUL:
        return {
            "result": "unsupported",
            "stages": WORKS,
            "message": None,
            "why": "UIKit shows Accessibility no marked text, so Oops can't see the composition, and its paste replaces "
            "the composed text while a typo stays. Run and recorded, but outside pass and fail until Oops can see it.",
        }
    if case.get("reaction") == "ime" and editor in IME_UNSEEN:
        return {
            "result": "works",
            "stages": WORKS,
            "message": None,
            "why": "This field shows Accessibility no marked text, and a correction during the composition lands cleanly. "
            "Graded on what the field shows, as if the composition were committed.",
        }
    if case.get("reaction") == "ime":
        return {
            "result": "refuses",
            "stages": REFUSES,
            "message": "composing|composition|typing|input method|IME",
            "why": "An input method is composing at the caret. The marked text isn't the user's yet, and replacing text "
            "under it breaks the composition, so Oops should touch nothing and say to finish typing first.",
        }
    if editor == "monaco" and not selected:
        return {
            "result": "refuses",
            "stages": REFUSES,
            "message": "[Ss]elect",
            "why": "Monaco paints its lines and takes input in a hidden textarea that holds only the word before the caret "
            "(a page of lines only with a screen reader on). Oops can't see the draft, so it should ask for a selection, "
            "which Monaco does mirror into the textarea.",
        }
    if editor == "monaco":
        return {
            "result": "works",
            "stages": COPY,
            "message": None,
            "why": "Monaco mirrors only the selection into its hidden textarea, so Oops can correct a selection. After the "
            "paste, nothing can find the corrected span again (its selection sync is Chrome-only), so no revert or flash, "
            "as for copy-and-paste editors.",
        }
    return {
        "result": "works",
        "stages": WORKS,
        "message": None,
        "why": "The editor exposes its text (value, text markers or a selection) and takes pasted text: Oops should capture "
        "the draft, fix both typos without touching atoms or the rest, revert it, flash the fixes and anchor to the field.",
    }
