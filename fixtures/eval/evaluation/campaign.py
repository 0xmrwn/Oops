"""Prepare a private corpus and explicitly execute resumable judging, never generation."""

import hashlib
import json
from collections import Counter, defaultdict
from contextlib import nullcontext
from datetime import datetime, timezone
from pathlib import Path

from . import judges
from .judge_execution import run as run_judges
from .records import ROOT, append, digest, lines, load_run, lock, read_json, write_json
from .scoring import METRICS_VERSION, judge_records, resolved, select
from .tasks import code_judgment, collect, protocol_hash, same_verdict, validate


def now():
    return datetime.now(timezone.utc).isoformat()


def prepare(dev, held, out, dev_only=False):
    dev, held, out = Path(dev).expanduser(), Path(held).expanduser(), Path(out).expanduser().resolve()
    frozen = read_json(ROOT / "dataset.json")
    for name, path in [("dev", dev), *([] if dev_only else [("held", held)])]:
        if hashlib.sha256(path.read_bytes()).hexdigest() != frozen[name]["sha256"]:
            raise ValueError(
                f"{name} corpus differs from the reviewed freeze. Review and version the dataset before preparing it."
            )
    cases = lines(dev) + ([] if dev_only else lines(held))
    validate_cases(cases)
    if not dev_only and out.is_relative_to(ROOT.parents[1]):
        raise ValueError("Held-back cases must be prepared outside the repository.")
    payload = "".join(json.dumps(c, ensure_ascii=False, separators=(",", ":")) + "\n" for c in cases)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists() and out.read_text() != payload:
        raise ValueError("Output already contains a different corpus; choose a new path.")
    if not out.exists():
        temporary = out.with_suffix(".tmp")
        temporary.write_text(payload)
        temporary.chmod(0o600)
        temporary.replace(out)
    return {
        "cases": len(cases),
        "version": frozen["version"],
        "sha256": hashlib.sha256(payload.encode()).hexdigest(),
        "out": str(out),
        "generation_started": False,
    }


def validate_cases(cases):
    if not cases or len({c["id"] for c in cases}) != len(cases):
        raise ValueError("The corpus must be nonempty with unique case IDs.")
    families = defaultdict(set)
    for case in cases:
        if not isinstance(case.get("input"), str) or not isinstance(case.get("expected"), str):
            raise ValueError("Reviewed cases need input and expected text.")
        if case.get("split") not in {"dev", "held"} or case.get("origin") not in {
            "synthetic",
            "injected",
            "derived",
            "real",
        }:
            raise ValueError("Every case needs a supported split and origin.")
        if case["origin"] == "derived" and not case.get("family"):
            raise ValueError("Derived cases need a family identifier shared with their source.")
        families[case.get("family") or case["id"]].add(case["split"])
    if any(len(splits) > 1 for splits in families.values()):
        raise ValueError("A case family crosses development and held-back splits.")


def judge(
    directory,
    rubric,
    chosen="both",
    execute=False,
    limit=None,
    env_file=None,
    include_anchors=False,
    judge_split=None,
    codex_workers=1,
    decisions_workers=1,
):
    if codex_workers < 1 or decisions_workers < 1:
        raise ValueError("Judge workers must be positive.")
    workers = {"codex": codex_workers, "decisions": decisions_workers}
    # Lock before reading cached judgments: a second planner must not race a finishing writer.
    with lock(directory / ".judging.lock") if execute else nullcontext():
        return _judge(directory, rubric, chosen, execute, limit, env_file, include_anchors, judge_split, workers)


def _judge(directory, rubric, chosen, execute, limit, env_file, include_anchors, judge_split, workers):
    experiment, _, cases, records = load_run(directory)
    if not experiment:
        raise ValueError("Judging requires an immutable experiment snapshot; legacy runs are report-only.")
    if any(c.get("origin") not in {"synthetic", "injected", "derived"} for c in cases.values()):
        raise ValueError("Real drafts are private: this bootstrap judge command accepts synthetic/derived cases only.")
    tasks = collect(cases, records, rubric)
    stored = judge_records(directory, tasks)
    engines = ["decisions", "codex"] if chosen == "both" else [chosen]
    pending = [
        (task, [engine for engine in engines if engine not in stored[key]])
        for key, task in tasks.items()
        if (include_anchors or code_judgment(task) is None)
        and (judge_split is None or calibration_split(cases[task["evidence"]["case"]]) == judge_split)
    ]
    pending = [(t, engines) for t, engines in pending if engines]
    if limit is not None:
        pending = pending[:limit]
    plan = {
        "distinct_answers": len(tasks),
        "pending_answers": len(pending),
        "judge_calls": sum(len(e) for _, e in pending),
        "execute": execute,
        "judges": engines,
        "judge_split": judge_split,
        "workers": workers,
    }
    if not execute:
        return plan
    key = judges.api_key(env_file) if any("decisions" in es for _, es in pending) else None
    progress = run_judges(directory, rubric, pending, key, workers)
    if progress["status"] == "interrupted":
        raise KeyboardInterrupt
    return {**plan, **progress}


def calibration_split(case):
    family = case.get("family") or case["id"]
    return "validation" if int(digest(family)[:8], 16) % 3 == 0 else "development"


def save_label(directory, key, judgment, rubric, author="human"):
    if author not in {"human", "agent"}:
        raise ValueError("Labels must identify a human or agent author.")
    experiment, _, cases, records = load_run(directory)
    if not experiment:
        raise ValueError("Legacy runs are report-only. Review outputs from a snapshotted experiment.")
    tasks = collect(cases, records, rubric)
    task = tasks.get(key)
    if task is None:
        raise ValueError("The output or rubric changed. Reload this case before saving.")
    validate(judgment, task)
    case = cases[task["evidence"]["case"]]
    family = case.get("family") or case["id"]
    split = calibration_split(case)
    label = {
        "key": key,
        "reference_key": task["reference_key"],
        "case": case["id"],
        "family": family,
        "judge": author,
        "status": "ok",
        "rubric": digest(rubric),
        "at": now(),
        "judge_split": split,
        "judgment": judgment,
    }
    if author == "agent":
        label["annotator"] = {"kind": "agent", "name": "Codex assistant, current chat", "blind_to_model_identity": True}
    append(directory / "labels.jsonl", label)
    return {"saved": True, "judge_split": split}


def calibrate(directory, rubric):
    _, _, cases, records = load_run(directory)
    tasks = collect(cases, records, rubric)
    saved = judge_records(directory, tasks)
    latest = {(r["key"], r["judge"]): r for r in lines(directory / "judgments.jsonl") if r.get("key") in tasks}
    result = {
        "schema_version": 2,
        "measured_at": now(),
        "metrics_version": METRICS_VERSION,
        "judge_protocol": protocol_hash(),
        "rubric": digest(rubric),
        "status": "measurement only; no automatic judge approval",
        "panels": {},
        "reference_sources": dict(
            Counter(
                "human" if "human" in rows else "agent" for rows in saved.values() if "human" in rows or "agent" in rows
            )
        ),
    }
    for split in ("development", "validation"):
        panels = {}
        for engine in ("decisions", "codex"):
            eligible = [
                key
                for key, rows in saved.items()
                if (rows.get("human") or rows.get("agent") or {}).get("judge_split") == split
            ]
            attempted = [latest[(key, engine)] for key in eligible if (key, engine) in latest]
            references = [(rows.get("human") or rows.get("agent"), rows.get(engine)) for rows in saved.values()]
            pairs = [
                (label, model) for label, model in references if label and model and label.get("judge_split") == split
            ]
            confusion = Counter((h["judgment"]["fully_correct"], m["judgment"]["fully_correct"]) for h, m in pairs)
            labels = Counter(h["judgment"]["fully_correct"] for h, _ in pairs)
            bad = sum(h["judgment"]["fully_correct"] == "no" for h, _ in pairs)
            false_accept = sum(
                h["judgment"]["fully_correct"] == "no" and m["judgment"]["fully_correct"] == "yes" for h, m in pairs
            )
            edits = Counter()
            for human, model in pairs:
                for field in ("edits", "misses"):
                    model_by_id = {r["id"]: r["verdict"] for r in model["judgment"][field]}
                    edits.update((r["verdict"], model_by_id[r["id"]]) for r in human["judgment"][field])
            panels[engine] = {
                "n": len(pairs),
                "reference_answers": len(eligible),
                "attempted": len(attempted),
                "errors": sum(r["status"] != "ok" for r in attempted),
                "pending": len(eligible) - len(attempted),
                "resolved": sum(resolved(m["judgment"]) for _, m in pairs),
                "whole_answer_abstentions": sum(m["judgment"]["fully_correct"] == "uncertain" for _, m in pairs),
                "exact_matches": sum(same_verdict(h["judgment"], m["judgment"]) for h, m in pairs),
                "raw_whole_answer_false_acceptances": sum(
                    h["judgment"]["fully_correct"] == "no"
                    and m.get("metadata", {}).get("model_judgment", m["judgment"])["fully_correct"] == "yes"
                    for h, m in pairs
                ),
                "families": len({h["family"] for h, _ in pairs}),
                "reference_labels": dict(labels),
                "human_labels": dict(
                    Counter(h["judgment"]["fully_correct"] for h, _ in pairs if h["judge"] == "human")
                ),
                "reference_sources": dict(Counter(h["judge"] for h, _ in pairs)),
                "agreement": sum(a == b for (a, b), n in confusion.items() for _ in range(n)) / len(pairs)
                if pairs
                else None,
                "false_acceptances": false_accept,
                "unacceptable_answers": bad,
                "false_accept_rate": false_accept / bad if bad else None,
                "whole_answer_confusion": [
                    {"reference": a, "judge": b, "n": n} for (a, b), n in sorted(confusion.items())
                ],
                "edit_confusion": [{"reference": a, "judge": b, "n": n} for (a, b), n in sorted(edits.items())],
            }
        result["panels"][split] = panels
        predictions = []
        for key, rows in saved.items():
            reference = rows.get("human") or rows.get("agent")
            if reference and reference["judge_split"] == split:
                prediction, source = select(
                    tasks[key], {name: row for name, row in rows.items() if name in {"decisions", "codex"}}
                )
                predictions.append((reference, prediction, source))
        decided = [(ref, pred) for ref, pred, _ in predictions if resolved(pred)]
        panels["pipeline"] = {
            "reference_answers": len(predictions),
            "resolved": len(decided),
            "unresolved": len(predictions) - len(decided),
            "whole_matches_on_resolved": sum(
                ref["judgment"]["fully_correct"] == pred["fully_correct"] for ref, pred in decided
            ),
            "exact_matches_on_resolved": sum(same_verdict(ref["judgment"], pred) for ref, pred in decided),
            "false_acceptances": sum(
                ref["judgment"]["fully_correct"] == "no" and pred["fully_correct"] == "yes" for ref, pred in decided
            ),
            "sources": dict(Counter(source for _, _, source in predictions)),
            "reference_overrides_used": False,
        }
    write_json(directory / "calibration.json", result)
    return result
