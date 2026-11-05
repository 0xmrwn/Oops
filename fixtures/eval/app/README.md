# Eval review app

Historical claude.ai Artifact used for answer-key review. The current local results/review dashboard
is `fixtures/eval/dashboard/`; see `docs/eval.md`. This Artifact and its stored labels are retained.

The page the owner reviews the eval set and model answers on, and watches a run from. It ran as a private claude.ai
Artifact, built for an iPhone first. Its data lives in the
Artifact's database: the orchestrator fills it with `ArtifactData` and reads the labels back. Record shapes follow
`fixtures/eval/README.md`; this file says where each one goes.

- **Review**, in two queues. "Set answer key" (`target: expected`) asks of each proposed correction whether it is
  the one the reviewer wants: Keep, Wrong or Rewrite. "Grade models" (`target: output`) asks whether a model's correction is
  acceptable: Accept, Wrong or Rewrite. Each card states its question; each button says what it means in that
  queue. Swipe right, left and up do the same (up only once the card's text is scrolled to its end). Remove case,
  reasons, an optional note and Undo sit beside them. A card opens on the word-level edits to the draft; graded
  answers also show their difference from the answer key. The model behind an answer is never shown. Each queue
  explains itself once, the first time it opens, and again from its help button.
- **Monitor**: progress per lane and model, the leaderboard for any KPI with its 95% interval, quality against
  latency, and fully correct by language, length and error type.

On a keyboard: → agree, ← wrong, ↑ or E edit, D drop, Z undo, 1–5 reasons, N note.

## Collections

| Collection | Written by | Document id | Body |
|---|---|---|---|
| `cases` | orchestrator | the case id | a Case record |
| `queue` | orchestrator | `expected--<case>` or `output--<case>--<output_hash>` | a queue item |
| `labels` | the page | the queue item's id | a Label record |
| `lanes` | orchestrator | `<lane>--<provider>--<model>--<effort>`, `/` written `~` | run progress for one model |
| `kpis` | orchestrator | same as `lanes` | KPIs for one model |
| `meta` | orchestrator | `run` | the run shown in Monitor |

Ids use letters, digits and `_ - . ~ : @ +` only. The page reads at most 1,000 documents per collection.

### `cases`

The contract's Case record. Add `flag` only through the queue item.

```json
{"id": "en-xs-001", "input": "ping @alex about teh deploy", "expected": "ping @alex about the deploy",
 "alternatives": [], "label": "accepted", "origin": "synthetic", "lang": "en", "length": "xs",
 "tags": {"errors": ["transposition"], "register": "casual", "protected": ["mention"], "clean": false},
 "split": "dev", "version": "2026.10.1"}
```

### `queue`

One document per card. An `expected` item shows its case's `expected`, so editing the case updates the card. An
`output` item carries the model's answer and its hash, and nothing that names the model, provider or lane.

```json
{"target": "expected", "case": "fr-m-025", "output_hash": null, "output": null,
 "flag": "\"parait\" is valid under the 1990 spelling reform. Should restoring the circumflex count?"}
{"target": "output", "case": "en-xs-002", "output_hash": "e0130faa2887", "output": "Can you check if it's merged?",
 "why": "calibration", "order": 1}
```

Cards come flagged first (`flag` set), then by `order` (absent sorts last), then by id. A queue item whose case is
not in `cases` is not shown. `why` (`calibration`, `mismatch`) is for the orchestrator; the page doesn't show it.

### `labels`

The contract's Label record, written when the owner decides. Exactly the contract's fields:

```json
{"case": "en-xs-002", "target": "output", "output_hash": "e0130faa2887", "decision": "also_correct",
 "edited": null, "reasons": [], "note": null, "at": "2026-10-29T10:01:44Z"}
```

- `agree` (Keep, Accept): on `expected`, the proposed answer is right. On `output`, the answer is right and equals `expected` or
  one of `alternatives`.
- `also_correct` (Accept): on `output`, the answer is right and differs from `expected` and every alternative. The
  button says "adds to the key" when this is what it will write.
- `wrong` (Wrong), `edit` (Rewrite, with `edited`, the full corrected text), `drop` (Remove case).
- `reasons`: any of `overcorrected`, `missed`, `changed_tone`, `changed_language`, `unrealistic`, picked before the
  decision. `note`: free text or null.

There is one current label per item. Undo deletes the document; deciding again overwrites it.

### `lanes`

```json
{"lane": "api", "provider": "groq", "model": "qwen/qwen3.8-27b", "effort": "none", "total": 400, "done": 382,
 "deferred": 0, "errors": 0, "rate_limit_waits": 1, "wait_ms": 8900, "next_retry": null,
 "updated": "2026-10-29T16:40:00Z"}
```

`total` is cases × attempts. `done` counts final records without an error, `errors` final records with one,
`deferred` attempts held back by a daily cap until `next_retry` (a date). What's left is the rest. A model with
nothing left and nothing deferred folds into its lane's "finished" list.

### `kpis`

Every metric sits in `m` as `{v, lo, hi, n}`: `v` the value, `lo` and `hi` its 95% interval (omit them when there is
none), `n` what it is counted over. Rates are fractions from 0 to 1, times in milliseconds, cost in US dollars.

```json
{"lane": "api", "provider": "groq", "model": "qwen/qwen3.8-27b", "effort": "none", "cases": 200, "attempts": 400,
 "m": {"fully_correct": {"v": 0.71, "lo": 0.664, "hi": 0.752, "n": 400}, "...": {},
       "latency_p50_ms": {"v": 208, "lo": 194, "hi": 225}, "cost_per_success_usd": {"v": 0.0000312}},
 "by": {"lang": {"en": {"v": 0.73, "lo": 0.68, "hi": 0.78, "n": 280}},
        "length": {"xs": {"v": 0.8, "lo": 0.7, "hi": 0.87, "n": 80}},
        "errors": {"spelling": {"v": 0.75, "lo": 0.67, "hi": 0.82, "n": 120}}}}
```

Metric keys: `fully_correct`, `precision`, `recall`, `f05`, `clean_changed`, `protected_broken`, `harm_rate`,
`valid_rate`, `deadline_missed` (the 40-second deadline), `pass2`, `flip_rate`, `latency_p50_ms`, `latency_p95_ms`,
`ttft_p50_ms`, `ttft_p95_ms`, `cost_per_success_usd` (`v: null` on subscription lanes). `by` holds the fully
correct rate per category; its keys are the case tags (`lang`, `length`, `errors`, plus `clean` for clean text).

### `meta/run`

```json
{"run": "2026-10-29-a", "dataset": "2026.10.1", "prompt": "71713ebedb60", "cases": 200, "attempts": 2,
 "started": "2026-10-29T08:02:00Z", "updated": "2026-10-29T16:40:00Z", "demo": false}
```

`demo: true` puts a "Demo data" mark in the header.

## Writing and reading

Write with `ArtifactData` `batch`: at most 50 writes and 1 MiB per call, `set` for new documents. A write to an
existing document needs its `if_version`: keep the versions each batch returns, or read the documents first. Large
bodies go through `file_path` instead of inline `data`. Update progress and KPIs as a run goes; the page follows
every change live.

Read the labels with `ArtifactData` `list` on `labels` (`query.limit` up to 1,000, then `next_cursor`), and append
each body to `labels.jsonl`. The document id names the queue item, so an `output` label joins back to its result
through `case` and `output_hash`.

The demo data is still in the store. Before the real set goes in, delete every document in `cases`, `queue`,
`lanes` and `kpis`, and `meta/run`, and any `labels` written while trying the page.

## Files

`index.html` with `app.css`, `monitor.css`, `copy.js` (every queue and metric label), `diff.js` (word diff),
`store.js` (the database), `review.js` and `monitor.js`. Publish the page with the others as its `files`, and the `db` capability with
`{"rules": [{"path": "", "read": "interact", "write": "admin"}]}`.

`demo/` holds the invented cases and outputs. `demo/seed.py OUT_DIR` writes them as one JSON file per document plus
`batch-N.json` lists for `ArtifactData`. `demo/preview.py OUT_DIR` builds a local copy of the page on that data with
`demo/mock-db.js` in place of the database, for checking changes in a browser before publishing.
