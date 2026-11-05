#!/usr/bin/env python3
"""A development grid for right-to-left drafts, outside the committed set: combobox composers, Draft.js
and fields inside frames in the Chromium shells, each case once in Arabic and once in English as its
control. Phase 6's held-back cases found right-to-left weaker there; the committed set barely samples it.

  tools/rtl_grid.py DIR      writes DIR/cases.json; run it with `run.py --cases DIR`

The fresh held-back draw leaves these combinations out, so it still measures cases no fix was tuned on.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import matrix  # noqa: E402

CHROMIUM = ("chrome", "electron")
BASE = {"layout": "composer", "content": "plain", "reaction": "none", "target": "whole", "embedding": "page"}


def tuples():
    for shell in CHROMIUM:
        for engine in matrix.WEB["engine"]:
            yield {"engine": engine, "shell": shell, "reaction": "combobox"}
        for engine in (
            "prosemirror",
            "lexical",
            "slate",
            "quill",
            "draftjs",
            "ckeditor",
            "contenteditable",
            "textarea",
        ):
            yield {
                "engine": engine,
                "shell": shell,
                "reaction": "combobox",
                "content": "mentions",
                "target": "selection",
            }
        for target in matrix.WEB["target"]:
            for content in ("plain", "mentions"):
                yield {"engine": "draftjs", "shell": shell, "target": target, "content": content}
        for engine in ("input", "textarea", "contenteditable", "draftjs", "prosemirror"):
            for embedding in ("iframe", "xframe"):
                yield {"engine": engine, "shell": shell, "embedding": embedding}


def grid():
    cases, seen = [], set()

    def add(case):
        key = tuple(sorted(case.items()))
        if key not in seen and matrix.allowed(case):
            seen.add(key)
            cases.append({name: case[name] for name in matrix.WEB})

    for presentation in ("rtl", "normal"):
        for fields in tuples():
            add({**BASE, **fields, "presentation": presentation})
    # Every other pair of values, in right-to-left only: a covering array over the web dimensions.
    for seed in (61, 62):
        for case in matrix.pairwise({**matrix.WEB, "presentation": ["rtl"]}, seed=seed):
            add(case)
    return cases


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    cases = [matrix.finish(c, "web", i + 1, "d") for i, c in enumerate(grid())]
    (out / "cases.json").write_text(json.dumps(cases, indent=1, ensure_ascii=False) + "\n")
    print(f"{len(cases)} cases -> {out / 'cases.json'}")


if __name__ == "__main__":
    main()
