"""Shared evidence and conservative checks; raw model verdicts remain in metadata."""

import copy
import re


def breaks(text):
    return re.findall(r"\r\n|\r|\n", text)


def context(task, rubric):
    e = task["evidence"]
    return {
        "policy": rubric["policy"],
        "guidance": rubric.get("guidance", {}),
        "edit_labels": rubric["edit_labels"],
        "miss_labels": rubric["miss_labels"],
        "evidence": e,
        "approved_candidate": e["reference"] is not None and e["corrected"] in [e["reference"], *e["alternatives"]],
        "structure": {
            "unchanged": e["draft"] == e["corrected"],
            "draft_line_breaks": breaks(e["draft"]),
            "candidate_line_breaks": breaks(e["corrected"]),
        },
    }


def conservative(result, task):
    result = copy.deepcopy(result)
    changes, evidence = [], task["evidence"]
    edits = {e["id"]: e for e in evidence["edits"]}
    for row in result["edits"]:
        edit = edits[row["id"]]
        if breaks(edit["before"]) != breaks(edit["after"]):
            row.update(
                verdict="harmful", explanation="Exact line-break sequences changed; deterministic preservation check."
            )
            result["faithful"] = "no"
            changes.append(f"{row['id']}: exact line breaks changed")
    if evidence["draft"] == evidence["corrected"]:
        if result["faithful"] != "yes":
            result["faithful"] = "yes"
            changes.append("Unchanged draft preserves itself")
        for row in result["misses"]:
            if row["verdict"] == "satisfied":
                row.update(
                    verdict="missed",
                    explanation="A required reference correction cannot be applied in an unchanged draft.",
                )
                changes.append(f"{row['id']}: required correction absent in unchanged draft")
    bad = (
        result["faithful"] == "no"
        or any(x["verdict"] == "harmful" for x in result["edits"])
        or any(x["verdict"] == "missed" for x in result["misses"])
    )
    uncertain = result["faithful"] == "uncertain" or any(
        x["verdict"] == "uncertain" for f in ("edits", "misses") for x in result[f]
    )
    if bad and result["fully_correct"] != "no":
        result["fully_correct"] = "no"
        changes.append("Known harm, preservation violation or missed error precludes a complete pass")
    elif uncertain and result["fully_correct"] == "yes":
        result["fully_correct"] = "uncertain"
        changes.append("Uncertain components preclude a complete pass")
    return result, changes
