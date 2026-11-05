# Eval set and run records

The contract between the eval set, `oops-eval`, the judges and the review app. Each part reads and writes only
these files, so they can be built and changed apart. Everything is JSON Lines, one record per line, UTF-8.

## Locations

| What | Where | In the repository |
|---|---|---|
| Taxonomy, cases for tuning (`split: dev`) | `fixtures/eval/` | yes |
| Held-back cases (`split: held`) | `~/Library/Application Support/oops-eval/held-back/cases.jsonl` | no |
| Real cases from the debug log, style notes from real messages | `~/Library/Application Support/oops-eval/private/` | never |
| Run records, judgments, labels | `~/Library/Application Support/oops-eval/runs/<run>/` | no |

Real messages never leave the Mac except to providers whose terms say they neither keep nor train on
them. Synthetic cases are written fresh: no quotes, names or client details from real messages.

## Case: `cases.jsonl`

`oops-eval`'s `EvalCase` with optional fields added, so `oops-eval export` output is a valid case file as is.

```json
{"id": "en-s-042", "input": "ping @alex about teh deploy", "expected": "ping @alex about the deploy",
 "alternatives": [], "label": "accepted", "origin": "synthetic", "lang": "en", "length": "s",
 "tags": {"errors": ["transposition"], "register": "casual", "protected": ["mention"], "clean": false},
 "split": "dev", "version": "2026.10.1"}
```

- `label`: `accepted` (expected is the right answer), `clear` (nothing to fix: expected is the input), `rejected`
  and `invalid` (from the debug log: `rejected` holds a bad answer).
- `alternatives`: other answers that are also right, added by review and judging.
- `origin`: `synthetic`, `injected` (known errors added to correct text), `derived` (synthetic, modelled on real
  usage), `real` (debug log, private only).
- `lang`: `en`, `fr` or `mixed`. The set is 70% English, 30% French; a third of the French share mixes both.
- `length`, in characters of `input`: `xs` under 80, `s` 80–300, `m` 300–1,200, `l` 1,200–4,000, `xl`
  4,000–16,000 (the app's limit). 200 cases: 40, 70, 55, 30 and 5.
- `tags.errors`: types from the taxonomy (`fixtures/eval/taxonomy.md`); empty for clean text.
- `split`: `dev` (150, tuned on) or `held` (50, never tuned on). The baseline runs both; a future optimizer must not see held-back cases.
- `version`: the set's version; any change to a case makes a new one.

## Result: `runs/<run>/results/<lane>--<model>.jsonl`

One record per call. A run can be resumed: a case with a final record for an attempt isn't sent again, and an
attempt that hit a daily cap is retried on a later day.

```json
{"run": "2026-10-29-a", "dataset": "2026.10.1", "prompt": "71713ebedb60", "lane": "api", "provider": "groq",
 "model": "qwen/qwen3.8-27b", "model_reported": "qwen/qwen3.8-27b", "effort": "none", "surface": "chat-completions",
 "case": "en-s-042", "attempt": 1, "started": "2026-10-29T09:12:03.120Z",
 "queued_ms": 0, "ttft_ms": 180, "ttfc_ms": 190, "total_ms": 412, "harness_ms": null,
 "status": 200, "rate_limited": 0, "retries": 0, "finish": "stop", "request_id": "req_…",
 "tokens": {"in": 142, "out": 29, "reasoning": 0, "cached": 0}, "cost_usd": 0.000021,
 "raw": "{\"text\": \"…\"}", "output": "ping @alex about the deploy", "verdict": "exact",
 "checks": {"valid": true, "protected_kept": true, "clean_unchanged": null, "lang_kept": true},
 "error": null}
```

- `lane`: `api` (OpenAI-compatible chat completions), `claude` (`claude -p`), `chatgpt` (Responses API with
  ChatGPT sign-in). `surface` names the exact request shape, documented in `docs/eval.md`.
- `attempt`: each case runs twice (k = 2), finalists five times.
- Timing: `queued_ms` is time spent waiting on pacing, `ttft_ms` the first streamed token of any kind, `ttfc_ms`
  the first token of the answer itself, `total_ms` the complete answer, `harness_ms` the CLI's own start-up
  (`claude` lane).
- `verdict`: `oops-eval`'s own (`exact`, `overcorrected`, `changed`, `unchanged`, `unscored`, `invalid`,
  `error`). Judges add finer verdicts in their own file.
- `checks`: computed by code. `protected_kept`: every mention, URL, path, code span, line break and edge
  whitespace of the input is still there; `clean_unchanged`: for clean cases, output equals input;
  `lang_kept`: the output is in the input's language.
- Never in a record: keys, headers other than the request ID, error bodies.

A run also writes `runs/<run>/manifest.json`: lanes, models, dates, and per provider its documented limits,
the configured pace and the achieved request rate.

## Experiment snapshot

A new generation run writes `experiment.json`, `cases.jsonl` and `config.json` before its first call.
The snapshot pins schema version, input-file hashes, actual prompt/hash, source revision/hash, attempts
and limit. Resuming with a different identity is refused. Resolved model/effort drift is also refused.
The snapshot's cases preserve optional `family`: a real draft and all its derivatives share a split.
A run has one generator process; that process already parallelizes providers. Legacy shakedowns are
report-only, without a reproducible experiment identity.

New result fields: `elapsed_ms` is full wait including queueing/retries; `dropped_edits` counts model
changes refused by reconciliation. They are optional when reading historical records. `openai` names
paid Responses calls using the same request/parser as the `chatgpt` sign-in lane.

## Judgment: `runs/<run>/judgments.jsonl`

The local pipeline writes one append-only record per distinct answer and judge. Successful judgments
are reused; failures are retryable. `key` fingerprints input, output, all references, rubric/policy,
model/settings, alignment and judge-adapter source. Identical answers across attempts/lanes share work.
Raw model answers differing from reconciled text get a separate key. Model identity is not supplied
to the judges.

```json
{"key":"sha256…","case":"en-s-042","judge":"codex","rubric":"sha256…","at":"…",
 "status":"ok","elapsed_ms":1200,
 "judgment":{"edits":[{"id":"e0","verdict":"needed","explanation":"A transposition."}],
 "misses":[{"id":"r0","verdict":"satisfied","explanation":"The error was fixed."}],
 "fully_correct":"yes","faithful":"yes","explanation":"Correct and faithful."},
 "metadata":{"model":"gpt-6.1-sol","auth":"chatgpt","cli":"…","effort":"high"}}
```

- `judge`: `decisions` or `codex`; Decisions uses the project API key, Codex the subscription.
- `status`: `ok`, or `error` with a short safe error and no accepted judgment.
- Edit verdicts: `needed`, `optional`, `harmful`, `uncertain`.
- Reference-edit verdicts: `missed`, `satisfied` (including valid alternatives), `optional`, `uncertain`.
- Whole-answer fields: `yes`, `no`, `uncertain`. Every supplied edit ID must be returned exactly once.
- `metadata`: adapter/model details, timing/usage, raw model verdict and guard overrides; Decisions
  also retains categorical distributions, confidence and whole-answer predicate probabilities.
  Never credentials, auth headers or raw provider error bodies.

Code accepts reviewed clean drafts and approved clean alternatives. A dirty reference establishes
acceptability, not edit necessity. Sol may resolve Decisions abstentions where confident components
agree; confident disagreements remain unresolved. Automatic passes require a reviewed reference.
All model-based scores stay explicitly provisional pending human output-label validation.

## Owner review: `runs/<run>/labels.jsonl`

The local dashboard appends the same judgment shape with `judge: human`, `status: ok`, `key`, `reference_key`, `case`,
`family`, rubric hash, timestamp and `judge_split` (`development` or `validation`). The split is
assigned by case family; repeated answers cannot cross it. The latest human record per key overrides
model judgments. Agent-authored references use `judge: agent` and carry annotator provenance; they
never masquerade as human labels. Earlier labels remain in the file. `reference_key` binds evidence,
policy and label definitions separately from the judge cache, preserving annotations across judge
prompt/settings changes while rejecting changed evidence or policy.

The offline **answer-key** review is a different artifact, preserved in its original private packet.
Its 200 approvals are integrated through the frozen corpus and provenance in `dataset.json`; they
are not model-output calibration labels. Historical development annotations remain with the private review packet.
The old claude.ai Artifact's label format remains documented in `app/README.md` for historical export.

## Reports and progress

`manage.py score` computes reports without network access; `manage.py serve` renders those same
metrics and supports blind output review. The website has no inference endpoint. `progress/*.json`
contains provider pace/next-slot activity. `judge_progress.json` separates judging from generation.

Judgments, labels and generated reports live with private run files outside Git. Detailed commands,
and execution: [../../docs/eval.md](../../docs/eval.md). Metric denominators and provisional-state rules:
[How answers are scored](../../docs/eval.md#how-answers-are-scored).
