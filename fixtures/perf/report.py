#!/usr/bin/env python3
"""Summarises an Animation Hitches + Time Profiler trace of oops: hitches, main-thread load and
the heaviest main-thread frames from SwiftUI, AppKit and oops itself.
Usage: report.py <trace> [top-frames] [--under "<frame>"]: with --under, what that frame spends
its time in, as call paths three frames deep."""

import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter


def table(trace, schema):
    xml = subprocess.run(
        [
            "xcrun",
            "xctrace",
            "export",
            "--input",
            trace,
            "--xpath",
            f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
        ],
        capture_output=True,
        check=True,
    ).stdout
    node = ET.fromstring(xml).find("node")
    if node is None:
        return
    ids, cols = {}, [c.find("mnemonic").text for c in node.find("schema").findall("col")]

    def resolve(el):
        return ids[el.attrib["ref"]] if el is not None and "ref" in el.attrib else el

    for row in node.findall("row"):
        for el in row:
            for sub in el.iter():
                if "id" in sub.attrib:
                    ids[sub.attrib["id"]] = sub
        yield {c: resolve(el) for c, el in zip(cols, row)}, resolve


args = sys.argv[1:]
under = args[args.index("--under") + 1] if "--under" in args else None
args = [a for i, a in enumerate(args) if a != "--under" and (i == 0 or args[i - 1] != "--under")]
trace, top = args[0], int(args[1]) if len(args) > 1 else 25
callees = Counter()
try:
    hitches = [(int(r["start"].text) / 1e9, int(r["duration"].text) / 1e6) for r, _ in table(trace, "hitches")]
except subprocess.CalledProcessError:
    hitches = []  # Time Profiler alone records no hitches.
late = [h for h in hitches if h[1] > 20]
print(
    f"hitches: {len(hitches)}  over 20 ms: {len(late)}  total: {sum(d for _, d in hitches):.0f} ms  "
    f"worst: {max((d for _, d in hitches), default=0):.0f} ms"
)
if late:
    print("  over 20 ms at:", ", ".join(f"{s:.2f}s/{d:.0f}ms" for s, d in late[:30]))

main, inclusive, span = 0, Counter(), [None, None]
for r, resolve in table(trace, "time-profile"):
    if "Main Thread" not in r["thread"].attrib.get("fmt", ""):
        continue
    t = int(r["time"].text) / 1e9
    span = [t if span[0] is None else span[0], t]
    backtrace = r.get("stack")
    if backtrace is None:
        continue
    main += 1
    names = [resolve(f).attrib.get("name", "?") for f in backtrace.iter("frame")]  # Leaf first.
    for name in set(names):
        inclusive[name] += 1
    if under and under in names:
        i = names.index(under)
        callees[" > ".join(n[:60] for n in reversed(names[max(i - 6, 0) : i]))] += 1
seconds = (span[1] - span[0]) if span[0] is not None else 0
print(f"main thread busy: {main} ms over {seconds:.1f} s ({100 * main / max(seconds * 1000, 1):.1f}%)")
keys = (
    "oops",
    "Settings",
    "Drop",
    "Eyes",
    "Capsule",
    "Editor",
    "Glass",
    "Layout.sizeThatFits",
    "layout()",
    "setFrame",
    "hitTest",
    "renderDisplayList",
    "body.getter",
    "Transition",
    "Image",
    "Text",
    "Timeline",
)
shown = 0
for name, count in inclusive.most_common(4000):
    if any(k in name for k in keys) and "OopsMain" not in name:
        print(f"  {count:5d} ms  {name[:140]}")
        shown += 1
        if shown >= top:
            break
if under:
    print(f"under {under}:")
    for path, count in callees.most_common(top):
        print(f"  {count:5d} ms  {path}")
