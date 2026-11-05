#!/usr/bin/env python3
"""Write the review app's demo data as one JSON file per document, plus ArtifactData batch lists.

Usage: seed.py OUT_DIR. Each `OUT_DIR/batch-N.json` is a `writes` list of at most 50 entries for ArtifactData's
`batch` action, pointing at the document files beside it. Everything is invented and marked `demo: true`.
"""

import hashlib
import json
import math
import random
import sys
from pathlib import Path

HERE = Path(__file__).parent
VERSION = "2026.10.0-demo"
RUN = "demo-2026-10-28"

# lane, provider, model, effort, p50 ms, fully correct rate
MODELS = [
    ("api", "gemini", "gemini-flash-lite-latest", "none", 900, 0.74),
    ("api", "gemini", "gemini-3.8-flash", "low", 2500, 0.86),
    ("api", "gemini", "gemini-3.8-flash", "default", 27500, 0.89),
    ("api", "groq", "qwen/qwen3.8-27b", "none", 220, 0.71),
    ("api", "groq", "openai/gpt-oss-120b", "low", 800, 0.66),
    ("api", "cerebras", "qwen-3.8-27b", "none", 1100, 0.72),
    ("api", "cerebras", "gpt-oss-120b", "low", 400, 0.65),
    ("api", "mistral", "ministral-8b-latest", "none", 600, 0.58),
    ("api", "openrouter", "nvidia/nemotron-3.5-lightning:free", "default", 27000, 0.80),
    ("api", "openrouter", "google/gemma-4-31b-it:free", "none", 1600, 0.69),
    ("api", "cohere", "command-a-plus-05-2026", "none", 2800, 0.78),
    ("api", "cohere", "command-r7b-12-2024", "none", 800, 0.49),
    ("api", "cloudflare", "@cf/meta/llama-3.3-70b-instruct-fp8-fast", "none", 900, 0.63),
    ("claude", "anthropic", "claude-haiku-5-5", "none", 3200, 0.84),
    ("claude", "anthropic", "claude-sonnet-5-5", "low", 5200, 0.90),
    ("claude", "anthropic", "claude-opus-5-5", "low", 7800, 0.92),
    ("claude", "anthropic", "claude-fable-5-1", "none", 2600, 0.80),
    ("chatgpt", "openai", "gpt-6.1-sol", "none", 2100, 0.88),
    ("chatgpt", "openai", "gpt-6.1-sol", "low", 4800, 0.91),
    ("chatgpt", "openai", "gpt-6.1-mini", "none", 1300, 0.82),
    ("chatgpt", "openai", "gpt-6.1-mini", "low", 2400, 0.85),
]
# Attempts per category over the full 200-case set, twice each.
CATEGORIES = {
    "lang": {"en": 280, "fr": 80, "mixed": 40},
    "length": {"xs": 80, "s": 140, "m": 110, "l": 60, "xl": 10},
    "errors": {
        "spelling": 120,
        "apostrophe": 70,
        "agreement": 64,
        "accent": 48,
        "homophone": 40,
        "capitalization": 36,
        "punctuation": 30,
        "clean": 60,
    },
}


def length_bucket(text):
    n = len(text)
    return "xs" if n < 80 else "s" if n <= 300 else "m" if n <= 1200 else "l" if n <= 4000 else "xl"


def wilson(rate, n, z=1.96):
    hits = rate * n
    d = 1 + z * z / n
    mid = (hits / n + z * z / (2 * n)) / d
    half = z * math.sqrt(hits / n * (1 - hits / n) / n + z * z / (4 * n * n)) / d
    return {"v": round(rate, 4), "lo": round(max(0, mid - half), 4), "hi": round(min(1, mid + half), 4), "n": n}


def clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))


def model_id(lane, provider, model, effort):
    return f"{lane}--{provider}--{model.replace('/', '~')}--{effort}"


def case_doc(c):
    return {
        "id": c["id"],
        "input": c["input"],
        "expected": c["expected"],
        "alternatives": [],
        "label": "accepted" if c["input"] != c["expected"] else "clear",
        "origin": "synthetic",
        "lang": c["lang"],
        "length": length_bucket(c["input"]),
        "tags": {
            "errors": c["errors"],
            "register": c["register"],
            "protected": c.get("protected", []),
            "clean": c["input"] == c["expected"],
        },
        "split": "held" if c["id"].endswith(("5", "0")) else "dev",
        "version": VERSION,
        "demo": True,
    }


def kpi_doc(rng, lane, provider, model, effort, p50, q):
    n = 400
    lat = p50 * rng.uniform(0.9, 1.1)
    deadline = clamp((p50 - 9000) / 60000) if p50 > 9000 else rng.uniform(0, 0.006)
    m = {
        "fully_correct": wilson(q, n),
        "precision": wilson(clamp(q + rng.uniform(0.04, 0.1)), 900),
        "recall": wilson(clamp(q + rng.uniform(-0.02, 0.07)), 820),
        "clean_changed": wilson(clamp((1 - q) * rng.uniform(0.2, 0.6)), 60),
        "protected_broken": wilson(clamp((1 - q) * rng.uniform(0.02, 0.15)), 220),
        "harm_rate": wilson(clamp((1 - q) * rng.uniform(0.15, 0.4)), n),
        "valid_rate": wilson(clamp(1 - (1 - q) * rng.uniform(0.0, 0.12)), n),
        "deadline_missed": wilson(deadline, n),
        "pass2": wilson(clamp(q * q * rng.uniform(1.0, 1.12)), 200),
        "flip_rate": wilson(clamp((1 - q) * rng.uniform(0.2, 0.5)), 200),
        "latency_p50_ms": {"v": round(lat), "lo": round(lat * 0.93), "hi": round(lat * 1.08)},
        "latency_p95_ms": {"v": round(lat * rng.uniform(1.8, 3.2))},
        "ttft_p50_ms": {"v": round(lat * rng.uniform(0.25, 0.6))},
        "ttft_p95_ms": {"v": round(lat * rng.uniform(0.8, 1.6))},
        "cost_per_success_usd": {"v": None if lane != "api" else round(rng.uniform(0.000004, 0.00012) / q, 7)},
    }
    p, r = m["precision"]["v"], m["recall"]["v"]
    m["f05"] = {"v": round(1.25 * p * r / (0.25 * p + r), 4)}
    by = {
        group: {key: wilson(clamp(q + rng.uniform(-0.14, 0.08)), count) for key, count in cats.items()}
        for group, cats in CATEGORIES.items()
    }
    return {
        "lane": lane,
        "provider": provider,
        "model": model,
        "effort": effort,
        "cases": 200,
        "attempts": n,
        "m": m,
        "by": by,
    }


def lane_doc(rng, lane, provider, model, effort):
    total = 400
    deferred = rng.choice([24, 60, 112]) if provider in ("gemini", "openrouter") else 0
    errors = rng.choice([0, 0, 1, 2, 4, 7])
    done = total - deferred - errors - rng.choice([0, 0, 0, 0, 18, 46])
    waits = rng.randint(30, 140) if provider in ("cerebras", "gemini", "openrouter", "cohere") else rng.randint(0, 12)
    return {
        "lane": lane,
        "provider": provider,
        "model": model,
        "effort": effort,
        "total": total,
        "done": done,
        "deferred": deferred,
        "errors": errors,
        "rate_limit_waits": waits,
        "wait_ms": waits * rng.randint(4000, 14000),
        "next_retry": "2026-10-29" if deferred else None,
        "updated": "2026-10-28T16:40:00Z",
    }


def main(out):
    rng = random.Random(7)
    cases = json.loads((HERE / "cases.json").read_text()) + json.loads((HERE / "cases-long.json").read_text())
    docs = []  # (collection, doc_id, body)
    for c in cases:
        docs.append(("cases", c["id"], case_doc(c)))
        docs.append(
            (
                "queue",
                f"expected--{c['id']}",
                {"target": "expected", "case": c["id"], "output_hash": None, "output": None, "flag": c.get("flag")},
            )
        )
    for i, o in enumerate(json.loads((HERE / "outputs.json").read_text())):
        h = hashlib.sha256(o["output"].encode()).hexdigest()[:12]
        body = {
            "target": "output",
            "case": o["case"],
            "output_hash": h,
            "output": o["output"],
            "why": o["why"],
            "order": i,
        }
        docs.append(("queue", f"output--{o['case']}--{h}", body))
    for spec in MODELS:
        lane, provider, model, effort, p50, q = spec
        mid = model_id(lane, provider, model, effort)
        docs.append(("lanes", mid, lane_doc(rng, lane, provider, model, effort)))
        docs.append(("kpis", mid, kpi_doc(rng, *spec)))
    meta = {"run": RUN, "dataset": VERSION, "prompt": "71713ebedb60", "cases": 200, "attempts": 2}
    docs.append(
        ("meta", "run", meta | {"started": "2026-10-28T08:02:00Z", "updated": "2026-10-28T16:40:00Z", "demo": True})
    )

    out.mkdir(parents=True, exist_ok=True)
    writes = []
    for collection, doc_id, body in docs:
        path = out / collection / f"{doc_id}.json"
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(body, ensure_ascii=False))
        writes.append({"op": "set", "collection": collection, "doc_id": doc_id, "file_path": str(path)})
    for i in range(0, len(writes), 50):
        (out / f"batch-{i // 50 + 1}.json").write_text(json.dumps(writes[i : i + 50]))
    print(f"{len(writes)} documents in {math.ceil(len(writes) / 50)} batches under {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
