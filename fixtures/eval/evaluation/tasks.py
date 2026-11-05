"""One distinct answer is judged once, using the same evidence for both judges."""

import json
from functools import cache

from .alignment import VERSION, edits, signature
from .records import ROOT, digest

EDIT_VERDICTS = {"needed", "optional", "harmful", "uncertain"}
MISS_VERDICTS = {"missed", "satisfied", "optional", "uncertain"}
ANSWERS = {"yes", "no", "uncertain"}


@cache
def protocol_hash():
    return digest(
        {p: (ROOT / "evaluation" / p).read_text() for p in ("alignment.py", "tasks.py", "judges.py", "judge_guards.py")}
    )


def task_for(case, output, rubric):
    reference = case.get("expected")
    evidence = {
        "case": case["id"],
        "draft": case["input"],
        "corrected": output,
        "reference": reference,
        "alternatives": case.get("alternatives", []),
        "lang": case.get("lang"),
        "edits": edits(case["input"], output),
        "reference_edits": edits(case["input"], reference, "r") if reference is not None else [],
    }
    return {
        "key": digest({"evidence": evidence, "rubric": rubric, "alignment": VERSION, "protocol": protocol_hash()}),
        "reference_key": digest(
            {
                "evidence": evidence,
                "policy": rubric["policy"],
                "policy_version": rubric["policy_version"],
                "edit_labels": rubric["edit_labels"],
                "miss_labels": rubric["miss_labels"],
                "alignment": VERSION,
            }
        ),
        "evidence": evidence,
    }


def collect(cases, records, rubric):
    tasks = {}
    for record in records:
        if record["case"] not in cases:
            raise ValueError("A result names a case outside the experiment snapshot.")
        output = record.get("output")
        case = cases[record["case"]]
        if output is not None:
            task = task_for(case, output, rubric)
            tasks[task["key"]] = task
        raw = raw_text(record)
        if raw is not None and raw != output:
            task = task_for(case, raw, rubric)
            tasks[task["key"]] = task
    return tasks


def raw_text(record):
    try:
        obj = json.loads(record.get("raw") or "null")
        return obj["text"] if isinstance(obj, dict) and isinstance(obj.get("text"), str) else None
    except (ValueError, KeyError):
        return None


def code_judgment(task):
    e = task["evidence"]
    if e["reference"] is None:
        return None
    # An acceptable reference does not establish that every reference edit was necessary.
    # Only a reviewed clean draft establishes the absence of real errors without judging.
    if e["reference"] != e["draft"] or e["corrected"] not in [e["reference"], *e["alternatives"]]:
        return None
    return {
        "edits": [
            {"id": x["id"], "verdict": "optional", "explanation": "Approved alternative to a reviewed clean draft."}
            for x in e["edits"]
        ],
        "misses": [],
        "fully_correct": "yes",
        "faithful": "yes",
        "explanation": "Reviewed clean draft or its approved alternative; no necessary fixes.",
    }


def validate(judgment, task, consistency=True):
    e = task["evidence"]
    if not isinstance(judgment, dict) or set(judgment) != {
        "edits",
        "misses",
        "fully_correct",
        "faithful",
        "explanation",
    }:
        raise ValueError("Judge response has the wrong fields.")
    for field, targets, allowed in [
        ("edits", e["edits"], EDIT_VERDICTS),
        ("misses", e["reference_edits"], MISS_VERDICTS),
    ]:
        rows = judgment[field]
        if (
            not isinstance(rows, list)
            or not all(isinstance(x, dict) for x in rows)
            or len(rows) != len(targets)
            or {x.get("id") for x in rows} != {x["id"] for x in targets}
        ):
            raise ValueError(f"Judge response has missing or duplicate {field}.")
        for row in rows:
            if (
                set(row) != {"id", "verdict", "explanation"}
                or row["verdict"] not in allowed
                or not isinstance(row["explanation"], str)
            ):
                raise ValueError(f"Invalid {field} judgment.")
    if (
        judgment["fully_correct"] not in ANSWERS
        or judgment["faithful"] not in ANSWERS
        or not isinstance(judgment["explanation"], str)
    ):
        raise ValueError("Invalid whole-answer judgment.")
    if (
        consistency
        and judgment["fully_correct"] == "yes"
        and (
            judgment["faithful"] != "yes"
            or any(x["verdict"] in {"harmful", "uncertain"} for x in judgment["edits"])
            or any(x["verdict"] in {"missed", "uncertain"} for x in judgment["misses"])
        )
    ):
        raise ValueError("Judge's whole-answer verdict contradicts its edit judgments.")
    return judgment


def same_verdict(a, b):
    return all(a[k] == b[k] for k in ("fully_correct", "faithful")) and all(
        {x["id"]: x["verdict"] for x in a[k]} == {x["id"]: x["verdict"] for x in b[k]} for k in ("edits", "misses")
    )


def schema():
    def rows(values):
        return {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "id": {"type": "string"},
                    "verdict": {"type": "string", "enum": sorted(values)},
                    "explanation": {"type": "string"},
                },
                "required": ["id", "verdict", "explanation"],
            },
        }

    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "edits": rows(EDIT_VERDICTS),
            "misses": rows(MISS_VERDICTS),
            "fully_correct": {"type": "string", "enum": sorted(ANSWERS)},
            "faithful": {"type": "string", "enum": sorted(ANSWERS)},
            "explanation": {"type": "string"},
        },
        "required": ["edits", "misses", "fully_correct", "faithful", "explanation"],
    }


def matched_reference_edits(evidence):
    """For diagnostics only; alternative valid corrections still go to a judge."""
    applied = {signature(x) for x in evidence["edits"]}
    return sum(signature(x) in applied for x in evidence["reference_edits"])
