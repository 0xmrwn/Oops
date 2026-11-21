"""Preregistered local Fix comparison over an OopsEval run and its blind human labels."""

import math
from collections import Counter, defaultdict
from statistics import mean, variance

from .campaign import validate_cases
from .records import digest, lines, load_run, read_json
from .scoring import judge_records, percentile
from .tasks import collect, raw_text, task_for

STUDENTS = ("qwen-stock", "qwen-tuned", "liquid-stock", "liquid-tuned")
TEACHERS = ("luna", "haiku")
NATIVE = ("autocorrect", "apple-model", "proofread")
ROLES = STUDENTS + TEACHERS + NATIVE
VERSION = "blind-fix-v1"


def paired(differences, margin):
    """Two-sided 95% bound for independent family means in [-1, 1], including all-tie samples."""
    values = [mean(rows) for rows in differences.values()]
    n = len(values)
    if n < 2:
        return {"families": n, "decision": "inconclusive"}
    delta = mean(values)
    # Split alpha across Hoeffding and the two-sided empirical Bernstein bound before taking the narrower.
    radius = min(
        math.sqrt(2 * math.log(2 / 0.025) / n),
        math.sqrt(2 * variance(values) * math.log(4 / 0.025) / n) + 14 * math.log(4 / 0.025) / (3 * (n - 1)),
    )
    lo, hi = max(-1, delta - radius), min(1, delta + radius)
    passed = lo >= -margin if margin else lo > 0
    failed = hi < -margin if margin else hi <= 0
    return {
        "families": n,
        "delta": delta,
        "ci95": [lo, hi],
        "decision": "pass" if passed else "fail" if failed else "inconclusive",
    }


def performance(samples):
    """Only isolated-lab monotonic shortcut and terminal-editor event timestamps qualify."""
    warm, cold = [], []
    peak, size = [], set()
    for case, observation in samples:
        if not observation:
            continue
        started, finished = observation["shortcut_ns"], observation["editor_terminal_ns"]
        if type(started) is not int or type(finished) is not int or not 0 <= started <= finished:
            raise ValueError("Invalid monotonic shortcut timestamps.")
        ms = (finished - started) / 1_000_000
        if observation["state"] == "cold":
            cold.append(ms)
        elif observation["state"] == "warm":
            if 1 <= len(case["input"].split()) <= 30:
                warm.append((ms, observation["successful"]))
        else:
            raise ValueError("Shortcut sample needs cold or warm state.")
        if type(observation["successful"]) is not bool:
            raise ValueError("Shortcut samples need an explicit success flag.")
        for field in ("peak_rss_bytes", "download_bytes"):
            if type(observation[field]) is not int or observation[field] <= 0:
                raise ValueError("Shortcut samples need positive byte counts.")
        peak.append(observation["peak_rss_bytes"])
        size.add(observation["download_bytes"])
    if len(size) > 1:
        raise ValueError("Download size changed within one lane.")
    return {
        "warm_short_n": len(warm),
        "warm_p95_ms": percentile([ms for ms, _ in warm], 0.95),
        "successful_within_1s": sum(ok and ms <= 1000 for ms, ok in warm),
        "cold_ms": cold,
        "peak_rss_bytes": max(peak, default=None),
        "download_bytes": next(iter(size), None),
    }


def comparison(directory, rubric):
    experiment, manifest, cases, records = load_run(directory)
    if not experiment or experiment.get("kind", "generation") != "generation":
        raise ValueError("Comparison requires a frozen generation run.")
    plan = read_json(directory / "config.json").get("comparison", {})
    roles = plan.get("lanes", {})
    if plan.get("protocol") != VERSION or set(roles) != set(ROLES) or len(set(roles.values())) != len(ROLES):
        raise ValueError("Freeze the comparison protocol and nine distinct lane files in the generation config.")
    if manifest["attempts"] != 1 or {lane["file"] for lane in manifest["lanes"]} != set(roles.values()):
        raise ValueError("Use exactly the registered lanes and one first attempt per case.")
    validate_cases(list(cases.values()))
    fixture = plan.get("purpose") == "fixture"
    if not fixture and (
        plan.get("purpose") != "qualification"
        or any(
            c["split"] != "held"
            or c["origin"] != "real"
            or not c.get("family")
            or c.get("lang") not in {"en", "fr", "mixed"}
            for c in cases.values()
        )
    ):
        raise ValueError("Qualification requires held-out real cases with family and language.")
    if plan.get("rubric_sha256") != digest(rubric):
        raise ValueError("The rubric differs from the comparison freeze.")
    timing = {}
    for sample in lines(directory / "shortcut.jsonl"):
        identity = (sample["role"], sample["case"])
        if identity in timing or sample["role"] not in roles or sample["case"] not in cases:
            raise ValueError("Duplicate or unregistered shortcut observation.")
        if sample["experiment"] != digest(experiment):
            raise ValueError("Shortcut measurement belongs to a different experiment.")
        timing[identity] = sample
    if not fixture:
        builds = plan.get("models", {})
        actual = {entry["file"]: entry.get("resolved") for entry in manifest["lanes"]}
        if set(builds) != set(roles) or any(
            not builds[role] or actual[file] != builds[role] for role, file in roles.items()
        ):
            raise ValueError("Registered and observed model or native build identifiers differ.")
    schedule = plan.get("shortcut_cases", {})
    if not fixture and (
        set(schedule.values()) != {"cold", "warm"}
        or not set(schedule) <= set(cases)
        or not any(state == "warm" and 1 <= len(cases[key]["input"].split()) <= 30 for key, state in schedule.items())
    ):
        raise ValueError("Freeze both cold and short warm shortcut cases before qualification.")
    if schedule and any(schedule.get(key) != sample["state"] for (_, key), sample in timing.items()):
        raise ValueError("Shortcut observation differs from its frozen schedule.")
    tasks = collect(cases, records, rubric)
    judgments = judge_records(directory, tasks)
    indexed = {(row["file"], row["case"]): row for row in records}
    summaries, scores, comparisons = {}, {}, {}
    for role, file in roles.items():
        scores[role] = {}
        totals, slices, samples = Counter(), defaultdict(Counter), []
        twins = defaultdict(list)
        for key, case in cases.items():
            row = indexed.get((file, key))
            output = row.get("output") if row else None
            failure = row is not None and (
                output is None or row.get("error") is not None or row.get("verdict") in {"invalid", "error"}
            )
            ballot = {}
            if output is not None:
                ballot = judgments[task_for(case, output, rubric)["key"]].get("human", {})
            send = False if failure else ballot.get("blind_send_as_is")
            harm = any(edit["verdict"] == "harmful" for edit in ballot.get("judgment", {}).get("edits", []))
            clean = case["expected"] == case["input"]
            counters = Counter(
                drafts=1,
                missing=int(row is None),
                failed=int(failure),
                awaiting_blind_vote=int(send is None),
                send_yes=int(send is True),
                harmful=int(harm),
                clean=int(clean),
                clean_success_unchanged=int(clean and not failure and output == case["input"]),
            )
            if row:
                checks = row.get("checks", {})
                counters["raw_protection_failed"] = int(checks.get("protected_kept") is False)
                counters["applied_protection_failed"] = int(checks.get("applied_protected_kept") is False)
                counters["applied_protection_unmeasured"] = int(checks.get("applied_protected_kept") is None)
                counters["raw_differs_from_applied"] = int(raw_text(row) is not None and raw_text(row) != output)
                samples.append((case, timing.get((role, key))))
                raw = raw_text(row)
                if raw is not None:
                    raw_label = judgments[task_for(case, raw, rubric)["key"]].get("human", {})
                    counters["raw_harmful"] = int(
                        any(e["verdict"] == "harmful" for e in raw_label.get("judgment", {}).get("edits", []))
                    )
                    counters["raw_reviewed"] = int(bool(raw_label))
            counters["fixed_sendable"] = int(not clean and send is True and output != case["input"])
            counters["clean_changed"] = int(clean and output is not None and output != case["input"])
            totals.update(counters)
            tags = case.get("tags", {})
            for group in [
                "lang/" + (case.get("lang") or "unknown"),
                "layout/" + (tags.get("layout") or "unknown"),
                *["error/" + error for error in tags.get("errors", [])],
            ]:
                slices[group].update(counters)
            scores[role][key] = send
            twins[(case.get("family") or key, case["input"])].append((case.get("instructions"), send))
        family_votes = defaultdict(list)
        for key, vote in scores[role].items():
            family_votes[cases[key].get("family") or key].append(vote)
        complete = not totals["awaiting_blind_vote"]
        pairs = [group for group in twins.values() if len({p for p, _ in group}) > 1]
        summaries[role] = {
            "counts": totals,
            "family_send_rate": mean(mean(votes) for votes in family_votes.values()) if complete else None,
            "clean_unchanged_rate": totals["clean_success_unchanged"] / totals["clean"] if totals["clean"] else None,
            "by_slice": slices,
            "timing": performance(samples),
            "preference_groups": len(pairs),
            "all_preferences_sendable": sum(all(v is True for _, v in group) for group in pairs),
        }
    for student in ("qwen-tuned", "liquid-tuned"):
        comparisons[student] = {}
        for baseline in (student.replace("tuned", "stock"), *TEACHERS, *NATIVE):
            differences = defaultdict(list)
            for key, case in cases.items():
                a, b = scores[student][key], scores[baseline][key]
                if a is None or b is None:
                    break
                differences[case.get("family") or key].append(int(a) - int(b))
            else:
                comparisons[student][baseline] = paired(differences, 0.03 if baseline in TEACHERS else 0)
                continue
            comparisons[student][baseline] = {"decision": "inconclusive", "reason": "incomplete paired review"}
    for student, paired_results in comparisons.items():
        model = summaries[student]
        counts, perf = model["counts"], model["timing"]
        complete_timing = bool(schedule) and all((student, key) in timing for key in schedule)
        quality = [paired_results[b]["decision"] for b in TEACHERS + NATIVE]
        clean_rate = model["clean_unchanged_rate"]
        gates = {
            "paired_quality": "fail"
            if "fail" in quality
            else "pass"
            if all(q == "pass" for q in quality)
            else "inconclusive",
            "clean_preservation": "inconclusive"
            if clean_rate is None or counts["missing"]
            else "pass"
            if clean_rate >= 0.99
            else "fail",
            "protected_spans": "fail"
            if counts["applied_protection_failed"]
            else "inconclusive"
            if counts["missing"] or counts["applied_protection_unmeasured"]
            else "pass",
            "shortcut_speed": "inconclusive"
            if not complete_timing or not perf["warm_short_n"]
            else "pass"
            if perf["warm_p95_ms"] < 1000 and perf["successful_within_1s"] >= 0.95 * perf["warm_short_n"]
            else "fail",
        }
        model["gates"] = gates
        model["qualification"] = (
            "fixture only"
            if fixture
            else "fail"
            if "fail" in gates.values()
            else "pass"
            if all(v == "pass" for v in gates.values())
            else "inconclusive"
        )
    return {
        "protocol": VERSION,
        "purpose": plan["purpose"],
        "fixture_only": fixture,
        "models": summaries,
        "paired_send_as_is": comparisons,
    }
