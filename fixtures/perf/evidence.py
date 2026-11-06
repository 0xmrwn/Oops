"""Validated performance samples and distributions; no app or profiler control."""

import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path

METRICS = {
    "launch_ms": "ms",
    "idle_rss_mib": "MiB",
    "hotkey_to_capsule_ms": "ms",
    "capture_ms": "ms",
    "apply_ms": "ms",
    "settings_switch_ms": "ms",
    "capsule_frame_ms": "ms",
}
CONDITIONS = ("first-after-boot", "cold-process", "warm-process")
CONTEXT_FIELDS = {
    "workload",
    "condition",
    "display_hz",
    "display_mode",
    "reduce_motion",
    "appearance",
    "power",
    "provider",
    "model",
    "host_app",
    "host_version",
}
SAMPLE_FIELDS = {"metric", "value", "case", "condition", "outcome", "source"}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def validate_context(context):
    if not isinstance(context, dict) or set(context) != CONTEXT_FIELDS:
        raise ValueError(f"context requires exactly these fields: {', '.join(sorted(CONTEXT_FIELDS))}")
    if not positive(context["display_hz"]):
        raise ValueError("display_hz must be an observed positive refresh rate")
    if context["condition"] not in CONDITIONS or type(context["reduce_motion"]) is not bool:
        raise ValueError("invalid condition or reduce_motion (must be boolean)")
    for key in CONTEXT_FIELDS - {"display_hz", "reduce_motion"}:
        if not isinstance(context[key], str) or not context[key].strip():
            raise ValueError(f"{key} must be a nonempty string")
    return context


def validate_sample(sample):
    if not isinstance(sample, dict) or set(sample) != SAMPLE_FIELDS:
        raise ValueError(f"sample requires exactly these fields: {', '.join(sorted(SAMPLE_FIELDS))}")
    if sample["metric"] not in METRICS or sample["condition"] not in CONDITIONS:
        raise ValueError("unknown metric or condition")
    for field in ("case", "outcome", "source"):
        if not isinstance(sample[field], str) or not sample[field].strip():
            raise ValueError(f"sample {field} must be nonempty")
    value = sample["value"]
    if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or value < 0):
        raise ValueError("sample value must be finite and nonnegative, or null for a missing measurement")
    return sample


def percentile(values, quantile):
    """Nearest-rank percentile; retain n so small cohorts cannot masquerade as tail evidence."""
    return values[max(0, math.ceil(len(values) * quantile) - 1)]


def summarize(path):
    groups = defaultdict(list)
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            continue
        sample = validate_sample(json.loads(line))
        key = tuple(sample[name] for name in ("metric", "case", "condition", "outcome", "source"))
        groups[key].append(sample["value"])
    result = []
    for key, values in sorted(groups.items()):
        measured = sorted(value for value in values if value is not None)
        row = dict(zip(("metric", "case", "condition", "outcome", "source"), key))
        row.update(
            unit=METRICS[key[0]],
            n=len(measured),
            missing=len(values) - len(measured),
            status="measured" if measured else "pending",
        )
        if measured:
            row.update(
                p50=percentile(measured, 0.5),
                p95=percentile(measured, 0.95),
                p99=percentile(measured, 0.99),
                maximum=measured[-1],
            )
        result.append(row)
    return {
        "groups": result,
        "pending_metrics": sorted(set(METRICS) - {r["metric"] for r in result if r["n"]}),
        "percentile_method": "nearest-rank",
        "acceptance": "not-assessed",
    }


def timings(log_path, selection_path):
    """Extract only timing scalars from explicitly selected diagnostic attempts, never draft text."""
    selection = read_json(selection_path)
    if not isinstance(selection, dict) or not selection:
        raise ValueError("selection must map attempt UUIDs to case and condition")
    for item in selection.values():
        if (
            not isinstance(item, dict)
            or set(item) != {"case", "condition"}
            or not isinstance(item["case"], str)
            or not item["case"].strip()
            or item["condition"] not in CONDITIONS
        ):
            raise ValueError("each selected attempt requires a nonempty case and a valid condition")
    found, samples = set(), []
    for line in Path(log_path).read_text().splitlines():
        row = json.loads(line)
        identifier = row.get("id")
        if row.get("kind") != "attempt" or identifier not in selection:
            continue
        if row.get("v") != 1 or identifier in found:
            raise ValueError("unsupported diagnostic version or duplicate selected attempt")
        found.add(identifier)
        # Outcomes are enums; arbitrary error/reason/model strings never leave the private log.
        outcome = row.get("outcome")
        if outcome not in {"fixed", "clear", "skipped", "pending", "failed", "cancelled"}:
            raise ValueError("unknown diagnostic outcome")
        for stage in ("capture", "apply"):
            sample = {
                "metric": stage + "_ms",
                "value": row.get("timings", {}).get(stage),
                **selection[identifier],
                "outcome": outcome,
                "source": "diagnostic-v1",
            }
            samples.append(validate_sample(sample))
    if found != set(selection):
        raise ValueError("selected attempts missing from log; no partial extraction returned")
    return {
        "samples": samples,
        "attempts": len(found),
        "log_sha256": digest(log_path),
        "selection_sha256": digest(selection_path),
        "provenance": "operator-selected; correlate with Release session",
    }
