#!/usr/bin/env python3
"""Reliability bake-off: drives Oops through every case and scores each stage against what the case
expects (docs in fixtures/bakeoff/README.md).

Builds and installs the Debug Oops like fixtures/e2e (stub provider, no model is called, nothing is
sent), starts each shell once (browsers with throwaway profiles), and runs its cases. Brings windows
to the front and types into them: don't run it while someone is using the Mac.

Usage: fixtures/bakeoff/run.py [--no-build] [--cases DIR] [--out FILE] [filter ...]
  --cases DIR   run the case files in DIR (*.json, lists of cases) instead of the committed set; the
                score goes next to DIR (DIR/../score-<name>.json) unless --out says otherwise
  --out FILE    where the score goes (default .build/bakeoff/score.json for the committed set)
  filter        a case id prefix, a set (web, native, edge, sanity), a host (chrome, qt, ...) or an engine
                or toolkit name; several filters add up
"""

import json
import shutil
import sys
import tempfile
import time
from collections import Counter, defaultdict
from pathlib import Path

from grade import CaseRun
from hosts import HOSTS, host_of, installed
from oops import Oops, e2e
from server import Server

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DIMENSIONS = ["engine", "toolkit", "shell", "layout", "content", "reaction", "presentation", "target", "embedding"]


def load(directory):
    cases = []
    for file in sorted(Path(directory).glob("*.json")):
        cases += json.loads(file.read_text())
    return cases


def matches(case, wanted):
    if not wanted:
        return True
    names = {case["id"], case["family"], host_of(case), case.get("engine"), case.get("toolkit")}
    if case["id"][0] in "es":
        names.add({"e": "edge", "s": "sanity"}[case["id"][0]])
    return any(w in names or case["id"].startswith(w) for w in wanted)


def summary(results):
    graded = [r for r in results if r["verdict"] not in ("fixture-error", "unrunnable", "unsupported")]
    stages = defaultdict(Counter)
    for r in graded:
        for stage, ok in r["stages"].items():
            stages[stage]["pass" if ok else "fail"] += 1
    by = defaultdict(lambda: defaultdict(Counter))
    for r in graded:
        for name in DIMENSIONS:
            if r.get(name):
                by[name][r[name]][r["verdict"]] += 1
    return {
        "cases": len(results),
        "graded": len(graded),
        "passed": sum(r["verdict"] == "pass" for r in graded),
        "fixture_errors": [r["id"] for r in results if r["verdict"] == "fixture-error"],
        "known_unrunnable": [r["id"] for r in results if r["verdict"] == "unrunnable"],
        "unsupported": [r["id"] for r in results if r["verdict"] == "unsupported"],
        "score": round(sum(r["verdict"] == "pass" for r in graded) / len(graded), 3) if graded else None,
        "by_expectation": {
            e: dict(Counter(r["verdict"] for r in graded if r["expect"] == e)) for e in ("works", "refuses")
        },
        "stages": {s: dict(c) for s, c in stages.items()},
        "by_dimension": {
            n: {v: f"{c['pass']}/{c['pass'] + c['fail']}" for v, c in sorted(values.items())}
            for n, values in by.items()
        },
    }


def main():
    args = sys.argv[1:]
    options = {}
    for flag in ("--cases", "--out"):
        if flag in args:
            i = args.index(flag)
            options[flag] = Path(args[i + 1]).expanduser().resolve()
            del args[i : i + 2]
    skip_build = "--no-build" in args
    wanted = [a for a in args if a != "--no-build"]
    source = options.get("--cases") or HERE / "cases"
    out = options.get("--out") or (
        source.parent / f"score-{source.name}.json" if "--cases" in options else ROOT / ".build/bakeoff/score.json"
    )
    cases = [c for c in load(source) if matches(c, wanted)]
    if not cases:
        sys.exit("bakeoff: no case matches")
    skipped = sorted({host_of(c) for c in cases if not installed(host_of(c)) and host_of(c) in ("chrome", "zen")})
    cases = [c for c in cases if host_of(c) not in skipped]
    Oops.build(skip_build)
    work = Path(tempfile.mkdtemp(prefix="oops-bakeoff-"))
    oops, server = Oops(work), Server()
    results, started = [], time.time()

    def save(complete=False):
        score = {
            "date": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "source": str(source),
            "seconds": round(time.time() - started),
            "complete": complete,
            "skipped_hosts": skipped,
            "summary": summary(results),
            "cases": results,
        }
        out.parent.mkdir(parents=True, exist_ok=True)
        temporary = out.with_suffix(out.suffix + ".tmp")
        temporary.write_text(json.dumps(score, indent=1, ensure_ascii=False) + "\n")
        temporary.replace(out)
        return score

    order = list(HOSTS)
    groups = sorted({host_of(c) for c in cases}, key=order.index)
    try:
        oops.start()
        nonce = 0
        for name in groups:
            host = HOSTS[name](server.url)
            host.prepare()
            host.start()
            try:
                for index, case in enumerate(c for c in cases if host_of(c) == name):
                    nonce += 1
                    try:
                        result = CaseRun(oops, server, host, case, nonce).run(first=index == 0)
                    except e2e.ScreenUnavailable:
                        raise
                    except Exception as error:  # one case's trouble shouldn't end the run
                        result = {
                            "id": case["id"],
                            "family": case["family"],
                            "host": name,
                            "expect": case["expect"]["result"],
                            "verdict": "fixture-error",
                            "notes": [f"runner: {error!r}"],
                        }
                    result.update({k: case[k] for k in DIMENSIONS if k in case})
                    results.append(result)
                    save()
                    stages = " ".join(
                        f"{s}:{'ok' if v else '--' if v is None else 'no'}"
                        for s, v in (result.get("stages") or {}).items()
                    )
                    print(f"{result['verdict']:<13} {case['id']:<34} {stages}", flush=True)
                    for note in result.get("notes") or []:
                        print(f"{'':14}{note[:300]}", flush=True)
            finally:
                host.stop()
    finally:
        save()
        oops.stop()
        server.stop()
        shutil.rmtree(work, ignore_errors=True)
    score = save(complete=True)
    s = score["summary"]
    print(
        f"\n{s['passed']}/{s['graded']} passed, {len(s['fixture_errors'])} fixture errors, in {score['seconds']} s -> {out}"
    )


if __name__ == "__main__":
    main()
