#!/usr/bin/env python3
"""Build a local copy of the review app on the demo data, with an in-memory stand-in for the db capability.

Usage: preview.py OUT_DIR, then `python3 -m http.server --directory OUT_DIR`. Decisions land in the page's
`window.__writes`; a reload starts over from the demo data.
"""

import json
import shutil
import sys
from pathlib import Path

import seed

APP = Path(__file__).parent.parent
HEAD = (
    '<!doctype html><html><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
    "<style>body{margin:0}[hidden]{display:none!important}</style></head><body>\n"
)


def main(out):
    seed.main(out / "seed")
    docs = {}
    for path in (out / "seed").glob("*/*.json"):
        docs.setdefault(path.parent.name, {})[path.stem] = json.loads(path.read_text())
    (out / "seed.js").write_text(f"window.SEED={json.dumps(docs, ensure_ascii=False)};")
    shutil.copy(APP / "demo" / "mock-db.js", out / "mock-db.js")
    for name in ("app.css", "monitor.css", "copy.js", "diff.js", "store.js", "review.js", "monitor.js"):
        shutil.copy(APP / name, out / name)
    page = (
        (APP / "index.html")
        .read_text()
        .replace(
            '<script src="diff.js">',
            '<script src="seed.js"></script><script src="mock-db.js"></script><script src="diff.js">',
        )
    )
    (out / "index.html").write_text(HEAD + page + "</body></html>\n")
    print(f"python3 -m http.server --directory {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
