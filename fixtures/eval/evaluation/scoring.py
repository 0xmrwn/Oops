"""Scores are derived from saved generations and versioned judgments, never from model calls."""

import fcntl
import json
import math
import random
from collections import Counter, defaultdict
from datetime import datetime
from functools import lru_cache

from .records import ROOT, canonical, digest, lines, load_run, read_json
from .tasks import code_judgment, collect, raw_text, same_verdict, task_for, validate

METRICS_VERSION = "minimal-edits-v3"


@lru_cache(maxsize=8192)
def report_task(case_json, output, rubric_json):
    # A live refresh adds a few outputs; alignment of the unchanged history is expensive.
    return task_for(json.loads(case_json), output, json.loads(rubric_json))


def percentile(values, fraction):
    values = sorted(x for x in values if x is not None)
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def interval(rows, cases):
    groups = defaultdict(list)
    for record, value in rows:
        case = cases[record["case"]]
        groups[case.get("family") or case["id"]].append(value)
    if len(groups) < 2:
        return None
    units, rng, estimates = list(groups.values()), random.Random(0), []
    for _ in range(400):
        sample = [x for group in rng.choices(units, k=len(units)) for x in group]
        estimates.append(sum(sample) / len(sample))
    return [percentile(estimates, 0.025), percentile(estimates, 0.975)]


def judge_records(directory, tasks):
    by_key = defaultdict(dict)
    references = {task["reference_key"]: task for task in tasks.values()}
    for filename in ("judgments.jsonl", "labels.jsonl"):
        for row in lines(directory / filename):
            judge = row.get("judge")
            task = (
                references.get(row.get("reference_key"))
                if judge in {"human", "agent"} and row.get("reference_key")
                else tasks.get(row.get("key"))
            )
            if task is None or row.get("status") != "ok":
                continue
            if judge not in {"decisions", "codex", "human", "agent"}:
                continue
            validate(row["judgment"], task)
            by_key[task["key"]][judge] = row
    return by_key


def select(task, rows):
    if "human" in rows:
        return rows["human"]["judgment"], "human"
    if "agent" in rows:
        return rows["agent"]["judgment"], "agent"
    known = code_judgment(task)
    if known is not None:
        return known, "code"
    if "decisions" in rows and "codex" in rows:
        a, b = rows["decisions"]["judgment"], rows["codex"]["judgment"]
        if same_verdict(a, b):
            if b["fully_correct"] == "yes" and task["evidence"]["reference"] is None:
                return None, "reference_required"
            return b, "agreement"
        compatible = all(
            a[k] == "uncertain" or b[k] == "uncertain" or a[k] == b[k] for k in ("fully_correct", "faithful")
        )
        for field in ("edits", "misses"):
            by_id = {r["id"]: r["verdict"] for r in b[field]}
            compatible = compatible and all(
                r["verdict"] == "uncertain" or by_id[r["id"]] == "uncertain" or r["verdict"] == by_id[r["id"]]
                for r in a[field]
            )
        if resolved(b) and compatible:
            if b["fully_correct"] == "yes" and task["evidence"]["reference"] is None:
                return None, "reference_required"
            return b, "sol_escalation"
        if compatible:
            return None, "uncertain"
        return None, "disagreement"
    return None, "pending"


def resolved(judgment):
    return (
        judgment is not None
        and judgment["fully_correct"] != "uncertain"
        and judgment["faithful"] != "uncertain"
        and all(row["verdict"] != "uncertain" for name in ("edits", "misses") for row in judgment[name])
    )


def aggregate(rows, cases, with_interval=True, attempts=2):
    completed = [(r, j) for r, j, _ in rows if resolved(j)]
    failures = [r for r, _, _ in rows if r.get("output") is None]
    known = len(completed) + len(failures)
    count = len(rows)
    full = sum(j["fully_correct"] == "yes" for _, j in completed)
    counts = Counter(x["verdict"] for _, j in completed for x in j["edits"])
    missed = sum(x["verdict"] == "missed" for _, j in completed for x in j["misses"])
    tp, fp = counts["needed"], counts["optional"] + counts["harmful"]
    precision = tp / (tp + fp) if tp + fp else None
    recall = tp / (tp + missed) if tp + missed else None
    f05 = 1.25 * tp / (1.25 * tp + 0.25 * missed + fp) if tp + fp + missed else None
    clean = [
        r
        for r, _, _ in rows
        if cases[r["case"]].get("tags", {}).get("clean")
        or cases[r["case"]].get("expected") == cases[r["case"]]["input"]
    ]
    by_case = defaultdict(list)
    for r, j in completed:
        by_case[r["case"]].append(j["fully_correct"] == "yes")
    for r in failures:
        by_case[r["case"]].append(False)
    repeated = [values for values in by_case.values() if attempts >= 2 and len(values) == attempts]
    known_rows = [(r, j["fully_correct"] == "yes") for r, j in completed] + [(r, False) for r in failures]
    list_value = (
        sum(r["cost_usd"] for r, _, _ in rows)
        if count and all(r.get("cost_usd") is not None for r, _, _ in rows)
        else None
    )
    api_cost = list_value if not any(r.get("lane") in {"chatgpt", "claude"} for r, _, _ in rows) else None
    return {
        "calls": count,
        "judged": known,
        "unresolved": count - known,
        "correct": full,
        "fully_correct": full / known if known else None,
        "fully_correct_bounds": [full / count, (full + count - known) / count] if count else None,
        "fully_correct_ci": interval(known_rows, cases) if with_interval and count and known == count else None,
        "precision": precision,
        "recall": recall,
        "f05": f05,
        "needed": tp,
        "optional": counts["optional"],
        "harmful": counts["harmful"],
        "missed": missed,
        "harm_rate": sum(
            any(x["verdict"] == "harmful" for x in j["edits"]) or j["faithful"] == "no" for _, j in completed
        )
        / len(completed)
        if completed
        else None,
        "clean_changed": sum(r.get("output") is not None and r["output"] != cases[r["case"]]["input"] for r in clean)
        / len(clean)
        if clean
        else None,
        "valid_rate": sum(r.get("checks", {}).get("valid", False) for r, _, _ in rows) / count if count else None,
        "protected_broken": sum(r.get("checks", {}).get("protected_kept") is False for r, _, _ in rows),
        "dropped_edits": sum(r.get("dropped_edits") or 0 for r, _, _ in rows),
        "errors": sum(r.get("verdict") == "error" for r, _, _ in rows),
        "invalid": sum(r.get("verdict") == "invalid" for r, _, _ in rows),
        "deadline_missed": sum("deadline" in (r.get("error") or "") for r, _, _ in rows),
        "latency_p50_ms": percentile([r.get("total_ms") for r, _, _ in rows if r.get("output") is not None], 0.5),
        "latency_p95_ms": percentile([r.get("total_ms") for r, _, _ in rows if r.get("output") is not None], 0.95),
        "wait_p50_ms": percentile([r.get("elapsed_ms") for r, _, _ in rows], 0.5),
        "wait_p95_ms": percentile([r.get("elapsed_ms") for r, _, _ in rows], 0.95),
        "ttft_p50_ms": percentile([r.get("ttft_ms") for r, _, _ in rows], 0.5),
        "ttfc_p50_ms": percentile([r.get("ttfc_ms") for r, _, _ in rows], 0.5),
        "rate_limited": sum(r.get("rate_limited", 0) for r, _, _ in rows),
        "retries": sum(r.get("retries", 0) for r, _, _ in rows),
        "cost_usd": api_cost,
        "list_value_usd": list_value,
        "cost_per_success_usd": api_cost / full if api_cost is not None and full and known == count else None,
        "pass2": sum(all(v) for v in repeated) / len(repeated) if repeated and attempts == 2 else None,
        "pass_all": sum(all(v) for v in repeated) / len(repeated) if repeated else None,
        "repeat_cases": len(repeated),
        "flip_rate": sum(any(v) != all(v) for v in repeated) / len(repeated) if repeated else None,
    }


def generating(directory, filename=".generation.lock"):
    path = directory / filename
    if not path.exists():
        return False
    with path.open() as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(stream, fcntl.LOCK_UN)
            return False
        except BlockingIOError:
            return True


def report(directory, rubric=None):
    rubric = rubric or read_json(ROOT / "rubric.json")
    experiment, manifest, cases, records = load_run(directory)
    encoded_cases, encoded_rubric = {key: canonical(case) for key, case in cases.items()}, canonical(rubric)

    def task(case_id, output):
        if case_id not in encoded_cases:
            raise ValueError("A result names a case outside the experiment snapshot.")
        return report_task(encoded_cases[case_id], output, encoded_rubric)

    tasks = {}
    for record in records:
        if record["case"] not in cases:
            raise ValueError("A result names a case outside the experiment snapshot.")
        for output in (record.get("output"), raw_text(record)):
            if output is not None:
                value = task(record["case"], output)
                tasks[value["key"]] = value
    saved = judge_records(directory, tasks)
    selected = {key: select(task, saved[key]) for key, task in tasks.items()}
    grouped = defaultdict(list)
    raw_grouped = defaultdict(list)
    for record in records:
        key = task(record["case"], record["output"])["key"] if record.get("output") is not None else None
        judgment, source = selected.get(key, (None, "failure"))
        grouped[record["file"]].append((record, judgment, source))
        raw = raw_text(record)
        raw_key = task(record["case"], raw)["key"] if raw is not None else None
        raw_judgment, raw_source = selected.get(raw_key, (None, "failure"))
        raw_grouped[record["file"]].append(({**record, "output": raw}, raw_judgment, raw_source))
    expected = len(cases) * manifest["attempts"]
    eligible = [lane for lane in manifest["lanes"] if lane["state"] != "skipped"]
    comparable = [
        set((r["case"], r["attempt"]) for r, j, _ in grouped[lane["file"]] if resolved(j) or r.get("output") is None)
        for lane in eligible
    ]
    common = set.intersection(*comparable) if comparable else set()
    lanes = []
    session_started = (manifest.get("sessions") or [{}])[-1].get("started")
    session_start = datetime.fromisoformat(session_started) if session_started else None
    for lane in manifest["lanes"]:
        rows = grouped[lane["file"]]
        slices = {}
        for dimension in ("lang", "length", "origin", "split", "errors"):
            buckets = defaultdict(list)
            for row in rows:
                case = cases[row[0]["case"]]
                values = (
                    case.get("tags", {}).get("errors", [])
                    if dimension == "errors"
                    else [case.get(dimension, "unknown")]
                )
                for value in values:
                    buckets[value].append(row)
            slices[dimension] = {
                key: {
                    k: value
                    for k, value in aggregate(bucket, cases, with_interval=False).items()
                    if k in {"calls", "judged", "correct", "fully_correct", "harmful", "missed"}
                }
                for key, bucket in buckets.items()
            }
        progress_file = (
            directory
            / "progress"
            / ("".join(c if c.isalnum() or c in "._-" else "_" for c in lane["provider"]) + ".json")
        )
        live = read_json(progress_file) if progress_file.exists() else None
        matched = [row for row in rows if (row[0]["case"], row[0]["attempt"]) in common]
        lanes.append(
            {
                **lane,
                "expected": lane["records"] if experiment and experiment.get("kind") == "calibration" else expected,
                "metrics": aggregate(rows, cases, attempts=manifest["attempts"]),
                "raw_metrics": aggregate(raw_grouped[lane["file"]], cases, attempts=manifest["attempts"]),
                "comparison": aggregate(matched, cases, attempts=manifest["attempts"]),
                "by": slices,
                "live": live,
                "session_calls": sum(
                    bool(session_start and r.get("started") and datetime.fromisoformat(r["started"]) >= session_start)
                    for r, _, _ in rows
                ),
            }
        )
    counts = Counter(source for _, source in selected.values())
    return {
        "schema_version": 1,
        "run": directory.name,
        "experiment": experiment,
        "manifest": manifest,
        "rubric": {
            "version": rubric["version"],
            "policy_version": rubric["policy_version"],
            "sha256": digest(rubric),
            "policy": rubric["policy"],
            "edit_labels": rubric["edit_labels"],
            "miss_labels": rubric["miss_labels"],
        },
        "metrics_version": METRICS_VERSION,
        "quality_status": "provisional; judges not yet validated against human output labels",
        "demo": bool(manifest.get("demo")),
        "generating": generating(directory),
        "cases": len(cases),
        "attempts": manifest["attempts"],
        "lanes": lanes,
        "judging": {
            "distinct_answers": len(tasks),
            "sources": dict(counts),
            "decisions_done": sum("decisions" in x for x in saved.values()),
            "codex_done": sum("codex" in x for x in saved.values()),
        },
        "comparison_calls": len(common),
        "case_index": [
            {
                "id": c["id"],
                "lang": c.get("lang"),
                "length": c.get("length"),
                "split": c.get("split"),
                "origin": c.get("origin"),
            }
            for c in cases.values()
        ],
    }


def case_detail(directory, identifier, rubric=None):
    rubric = rubric or read_json(ROOT / "rubric.json")
    _, _, cases, records = load_run(directory)
    if identifier not in cases:
        raise ValueError("Case not found.")
    relevant = [r for r in records if r["case"] == identifier]
    tasks = collect(cases, relevant, rubric)
    saved = judge_records(directory, tasks)
    answers = []
    for row in relevant:
        entry = {"record": row, "task": None, "judges": {}, "selected": None, "source": "failure"}
        if row.get("output") is not None:
            task = task_for(cases[identifier], row["output"], rubric)
            entry.update(task=task, judges=saved[task["key"]])
            entry["selected"], entry["source"] = select(task, entry["judges"])
        raw = raw_text(row)
        if raw is not None and raw != row.get("output"):
            raw_task = task_for(cases[identifier], raw, rubric)
            entry.update(raw_task=raw_task, raw_judges=saved[raw_task["key"]])
            entry["raw_judgment"], entry["raw_source"] = select(raw_task, entry["raw_judges"])
        answers.append(entry)
    return {"case": cases[identifier], "answers": answers}
