#!/usr/bin/env python3
"""The bake-off matrix: its dimensions, which value pairs can't exist, and a deterministic pairwise
generator, so every pair of values meets in at least one case without the full product.

  matrix.py              writes cases/web.json, native.json, edge.json and sanity.json (the committed set)
  matrix.py --check      fails if the committed cases differ from what the generator makes

Drafts and expected results are in drafts.py.
"""

import json
import random
import sys
from itertools import combinations
from pathlib import Path

from drafts import draft, expectation

HERE = Path(__file__).resolve().parent
SEED = 6  # Changing it reshuffles the committed set: only with a reason, and --check will say so.

WEB = {
    "engine": [
        "prosemirror",
        "lexical",
        "slate",
        "quill",
        "draftjs",
        "ckeditor",
        "tinymce",
        "codemirror",
        "monaco",
        "roosterjs",
        "trix",
        "blocks",
        "textarea",
        "input",
        "contenteditable",
    ],
    "shell": ["safari", "webkit", "chrome", "zen", "electron"],
    "layout": ["composer", "thread", "side-panel", "modal", "nested-scroll", "document"],
    "content": ["plain", "mentions", "emoji-images"],
    "reaction": ["none", "paste-intercept", "rerender", "slash-menu", "ime", "combobox"],
    "presentation": ["normal", "zoom", "rtl"],
    "target": ["whole", "selection", "multiline"],
    "embedding": ["page", "iframe", "xframe", "shadow"],
}
NATIVE = {
    "toolkit": [
        "appkit-tk1",
        "appkit-tk2",
        "appkit-field",
        "swiftui-editor",
        "swiftui-field",
        "swiftui-rich",
        "catalyst-textview",
        "catalyst-field",
        "custom-opaque",
        "qt",
        "swing",
    ],
    "layout": WEB["layout"],
    "content": WEB["content"],
    "reaction": [r for r in WEB["reaction"] if r != "combobox"],  # an ARIA role: web only
    "presentation": WEB["presentation"],
    "target": WEB["target"],
}
# Engines with no inline images: a plain field, or an editor whose text is its document (Monaco).
NO_IMAGES = {
    "textarea",
    "input",
    "monaco",
    "appkit-field",
    "swiftui-editor",
    "swiftui-field",
    "swiftui-rich",
    "catalyst-field",
    "custom-opaque",
    "qt",
    "swing",
}
SINGLE_LINE = {"input", "appkit-field", "catalyst-field"}
# Where a composition can be started without a person: through NSTextInputClient (WebKit app views,
# AppKit and SwiftUI text views, UIKit) or Qt's input method events. Browsers, Electron and Swing can't.
IME = {
    "webkit",
    "appkit-tk1",
    "appkit-tk2",
    "appkit-field",
    "swiftui-editor",
    "swiftui-field",
    "swiftui-rich",
    "catalyst-textview",
    "catalyst-field",
    "custom-opaque",
    "qt",
}
# Engines that can't mount in a shadow root: Draft.js reads the document's selection only, and
# TinyMCE's classic mode is an iframe of its own.
NO_SHADOW = {"draftjs", "tinymce"}


def allowed(case):
    """False when the values present can't meet; dimensions not set yet never rule a case out."""
    editor = case.get("engine") or case.get("toolkit")
    reaction, target = case.get("reaction"), case.get("target")
    if editor in NO_IMAGES and case.get("content") == "emoji-images":
        return False
    if editor in SINGLE_LINE and (target == "multiline" or case.get("layout") == "document"):
        return False
    if reaction == "ime" and any(key in case and case[key] not in IME for key in ("shell", "toolkit")):
        return False
    if reaction in ("slash-menu", "ime") and target == "selection":
        return False
    if case.get("embedding") == "shadow" and editor in NO_SHADOW:
        return False
    if editor == "custom-opaque" and reaction in ("rerender", "paste-intercept"):
        return False  # nothing outside the view reaches its text
    return True


def pairwise(dimensions, seed, avoid=()):
    """A greedy covering array: each new case is the best of 60 candidates at covering uncovered pairs."""
    names = list(dimensions)
    rng = random.Random(seed)
    uncovered = {
        ((a, x), (b, y))
        for a, b in combinations(names, 2)
        for x in dimensions[a]
        for y in dimensions[b]
        if allowed({a: x, b: y})
    }
    avoid = {tuple(sorted(c.items())) for c in avoid}
    cases = []
    while uncovered:
        best, best_score = None, -1
        for _ in range(60):
            (a, x), (b, y) = rng.choice(sorted(uncovered))
            case = {a: x, b: y}
            for name in rng.sample(names, len(names)):
                if name in case:
                    continue
                options = [v for v in dimensions[name] if allowed({**case, name: v})]
                rng.shuffle(options)
                case[name] = max(
                    options,
                    key=lambda v: sum(
                        ((n, case[n]), (name, v)) in uncovered or ((name, v), (n, case[n])) in uncovered for n in case
                    ),
                )
            if not allowed(case) or tuple(sorted(case.items())) in avoid:
                continue
            score = sum(((p, case[p]), (q, case[q])) in uncovered for p, q in combinations(names, 2))
            if score > best_score:
                best, best_score = case, score
        if best is None:
            continue
        cases.append({name: best[name] for name in names})
        uncovered -= {((p, best[p]), (q, best[q])) for p, q in combinations(names, 2)}
    return cases


def finish(case, family, index, prefix):
    """A case as the runner reads it: its dimensions, its draft, and what Oops should do."""
    editor = case.get("engine") or case.get("toolkit")
    app = next((name for name in ("catalyst", "qt", "swing") if editor.startswith(name)), "native")
    case_id = f"{prefix}{index:03d}-{editor}-{case.get('shell', app)}"
    return {"id": case_id, "family": family, **case, **draft(case), "expect": expectation(case)}


# Fields that must refuse: a password, a read-only document, and a canvas editor with nothing
# selected (its text is drawn, not exposed). A canvas with a selection goes through copy.
EDGE = [
    *(
        {
            "engine": "password",
            "shell": s,
            "layout": "modal",
            "content": "plain",
            "reaction": "none",
            "presentation": "normal",
            "target": "whole",
            "embedding": "page",
        }
        for s in WEB["shell"]
    ),
    *(
        {
            "engine": "readonly",
            "shell": s,
            "layout": "document",
            "content": "plain",
            "reaction": "none",
            "presentation": "normal",
            "target": "selection",
            "embedding": "page",
        }
        for s in WEB["shell"]
    ),
    *(
        {
            "engine": "canvas",
            "shell": s,
            "layout": "document",
            "content": "plain",
            "reaction": "none",
            "presentation": "normal",
            "target": t,
            "embedding": "page",
        }
        for s in WEB["shell"]
        for t in ("whole", "selection")
    ),
    *(
        {
            "toolkit": t,
            "layout": "modal",
            "content": "plain",
            "reaction": "none",
            "presentation": "normal",
            "target": "whole",
        }
        for t in ("appkit-secure", "catalyst-secure", "qt-secure", "swing-secure")
    ),
    {
        "toolkit": "appkit-readonly",
        "layout": "document",
        "content": "plain",
        "reaction": "none",
        "presentation": "normal",
        "target": "selection",
    },
]


# The simplest case for every engine in every shell: a composer, plain text, nothing in the way. When
# one fails, the engine or shell itself is the problem, not a dimension stacked on it. Monaco's is a
# selection, since that is all it exposes.
SANITY = [
    {
        "engine": e,
        "shell": s,
        "layout": "composer",
        "content": "plain",
        "reaction": "none",
        "presentation": "normal",
        "target": "selection" if e == "monaco" else "whole",
        "embedding": "page",
    }
    for e in WEB["engine"]
    for s in WEB["shell"]
]


def generate(seed=SEED):
    web = [finish(c, "web", i + 1, "w") for i, c in enumerate(pairwise(WEB, seed))]
    native = [finish(c, "native", i + 1, "n") for i, c in enumerate(pairwise(NATIVE, seed))]
    edge = [finish(c, "web" if "engine" in c else "native", i + 1, "e") for i, c in enumerate(EDGE)]
    sanity = [finish(c, "web", i + 1, "s") for i, c in enumerate(SANITY)]
    return {"web": web, "native": native, "edge": edge, "sanity": sanity}


def main():
    sets = generate()
    for name, cases in sets.items():
        path = HERE / "cases" / f"{name}.json"
        text = json.dumps(cases, indent=1, ensure_ascii=False) + "\n"
        if "--check" in sys.argv:
            if not path.exists() or path.read_text() != text:
                sys.exit(f"matrix: {path.name} differs from the generator; run fixtures/bakeoff/matrix.py")
        else:
            path.parent.mkdir(exist_ok=True)
            path.write_text(text)
    print(", ".join(f"{len(c)} {n}" for n, c in sets.items()) + " cases")


if __name__ == "__main__":
    main()
