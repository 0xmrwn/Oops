# Judge APIs: Jev and the Decisions API

The two decision models that judge every change first. Both take some content plus typed questions and return probabilities, never text. Checked on 28 October 2026 against each vendor's docs, with a live test from this Mac. How to word the questions, what the two judge papers found, and the recommended request design are in [judge-prompting.md](judge-prompting.md).

## At a glance

| | Jev (TypeSafe) | Decisions API (OpenAI) |
|---|---|---|
| Endpoint | `POST https://api.typesafe.ai/v1/systemone` | `POST https://api.openai.com/v1/decisions` |
| Auth | `Authorization: Bearer $TYPESAFE_API_KEY` | `Authorization: Bearer $OPENAI_API_KEY` |
| Model | `jev-1.14.0` (from 14 October 2026), `jev-1.13.0`; aliases `jev-latest`, `jev-preview` both → `jev-1.14.0` | `gpt-6-luna` only; no dated snapshot exists |
| Content field | `state`: string, JSON object or array | `input`: string, or messages (user, developer, system, assistant) and tool calls/outputs; JSON via `input_json` parts |
| Yes/no question | `noul` → `noul`: P(yes) | `predicate` → `probability`: P(true) |
| Pick one | `choice`: 1–255 options as `criteria` `{name: description}` → `choice`, `probabilities` `{name: p}`, `confidence` | `choice`: 2–255 `choices` `[{value, description}]` → `choice`, `probabilities` `[{value, probability}]`, `confidence` |
| Ordered levels | `score`: 1–10 `criteria` levels → expected `score`, `legend`, `probabilities`, `confidence` | `score`: 2–10 `levels` `[{label, description}]` → expected `score`, `probabilities`, `confidence` |
| Questions per request | Unlimited; fit 64k tokens per request and 32k per question (262k each with `TypeSafe-Danger-Zone-Long-Context: true`) | 1–400 |
| Question id | Your key in the `questions` object; not sent to the model | Optional `name`; answers come back in order |
| Refusals | Not documented | Any answer can be `{"type": "refusal"}` |
| Price | $0.042 per million input tokens; output free | $0.10 per million uncached input tokens, cached $0.01, cache writes $0.125; output free |
| Rate limits | Per organization, tokens and requests per second, shown in the console; 429 and 529 to retry | `gpt-6-luna` Build tier: 5,000 requests and 2M tokens a minute |
| Training on requests | No | No |
| Retention | Under TypeSafe's DPA; zero data retention for enterprise only | Abuse-monitoring logs up to 30 days; zero data retention for eligible customers; flagged content and a sample of requests may be kept for automated safety review |
| Language | English is the primary training language; other languages "handled but not equally well" | Not stated |

Sources: TypeSafe [Models](https://docs.typesafe.ai/models.md), [System One API](https://docs.typesafe.ai/api/system-one.md), [Noul](https://docs.typesafe.ai/primitives/noul.md), [Primitives](https://docs.typesafe.ai/primitives.md), [Request rules and errors](https://docs.typesafe.ai/api/errors.md), [Legal](https://docs.typesafe.ai/legal.md); OpenAI [Decisions guide](https://developers.openai.com/api/docs/guides/decisions), [create decision reference](https://developers.openai.com/api/reference/resources/decisions/methods/create), [GPT-6 Luna model page](https://developers.openai.com/api/docs/models/gpt-6-luna), [Data controls](https://developers.openai.com/api/docs/guides/your-data).

## Jev

```json
{"model": "jev-1.14.0",
 "state": {"policy": "…", "draft": "…", "corrected": "…", "change": {"before": "teh", "after": "the"}},
 "questions": {"needed": {"type": "noul", "instructions": "Does `change` fix a real mistake in `draft`…?",
                          "criteria": {"true": "…", "false": "…"}}}}
```

Response: `{"model": "jev-1.14.0", "answers": {"needed": {"type": "noul", "noul": 0.99}}, "usage": {"input_tokens": 635, "output_tokens": …}}`.

- **Questions.** `instructions` and `criteria` accept strings, objects or arrays, so a question can carry its own data or examples in named fields. Point at parts of the state with a backticked path such as `` `change.before` ``. All questions see the same state and are answered independently and in parallel: adding questions barely changes latency and costs only their tokens.
- **Noul** has no separate confidence: the value is the answer and its certainty. TypeSafe suggests starting at 0.7 for yes and 0.3 for no, sending the middle to review, then tuning on your own labels. Choice and Score return `confidence`, a statistic of the whole distribution whose formula is not published (JEV-as-a-Judge, §4).
- **Pinning.** An alias moves when a release ships, so answers can change with no change on our side. The response's `model` field names the version that answered (`jev-latest` returned `jev-1.14.0` in our test). Send `jev-1.14.0` and move only after recalibrating.
- **Limits.** Body at most 32 MiB, UTF-8 JSON, 64 levels of nesting, finite numbers; gzip or zstd accepted. Errors: 400, 401, 413, 415, 422 (validation), 429, 529.
- **Known weak spots** for 1.13 (TypeSafe's own list; none published yet for 1.14): literal reading of the question, counting and numbers, dates, indirection ("a property of a property"), large states full of irrelevant detail, text in the state that argues for its own label, instructions that contradict their criteria, and a lean toward the first Choice option ([Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md)).
- **SDKs**: `typesafe-sdk` (Python) and `@typesafe-ai/sdk`, which retry 429 and 529 with backoff.

## Decisions API

Generally available since its public beta of early October 2026.

```json
{"model": "gpt-6-luna",
 "input": [{"role": "user", "content": [{"type": "input_json", "data": {"policy": "…", "draft": "…", "change": {}}}]}],
 "questions": [{"type": "predicate", "name": "needed", "instructions": "Does `change` fix … ? Yes means: … No means: …"}]}
```

Response: `{"model": "gpt-6-luna", "answers": [{"type": "predicate", "name": "needed", "probability": 0.99}], "usage": {"input_tokens": 698, "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0}, "output_tokens": 0, …}}`.

- **Questions.** `instructions` is a string or an array of text, image and `input_json` parts. A predicate has no `criteria` field, so the yes and no definitions go in the instruction text. Choices are typed: `"true"` and `true` are different values.
- **Input.** `input_json` parts (32 levels, 10,000 values, 256 KiB) are rendered as text and only allowed in user messages. Developer and system messages take text only.
- **Prompt caching.** An implicit breakpoint sits at the end of `input`; the shared prefix must be at least 1,024 tokens, and question text is outside it. `prompt_cache_key` partitions reuse.
- **Other fields**: `prompt_cache_options`, `safety_identifier`. There is no `temperature`, `seed`, `store` or `metadata` field, and no dated model to pin.
- **Usage reporting**: `GET /v1/organization/usage/decisions` with an admin key.

## Live test

28 October 2026, from this Mac, with the keys from the repository's ignored `.env`. Nine invented judgments (needed fix, valid alternative, meaning change, tone change, added error, and a removed anglicism, in English, French and mixed text), each sent as one request with three yes/no questions, then repeated three times; plus variants. 119 requests in all, about 38,000 input tokens on Jev and 42,000 on Decisions: **under one cent in total**.

| | Jev `jev-1.14.0` | Decisions `gpt-6-luna` |
|---|---|---|
| Requests answered | 27/27 (repeat run), all 200 | 27/27, all 200 |
| Latency, three questions per request | p50 168 ms, p95 228 ms | p50 351 ms, p95 525 ms; one 2.2 s outlier in the first run |
| Input tokens per request (three questions with yes/no definitions) | 635 | 698 |
| Same request three times | answers moved by at most 0.09 (mean 0.018) | identical every time |
| Clear cases (needed, meaning change, added error, tone, anglicism) | all on the right side of 0.5, mostly beyond 0.1 or 0.9 | all on the right side, mostly 0.00 or 1.00 |
| `ok` → `OK` in casual text (label is a policy call) | needed 0.36–0.59 | needed 0.67–0.73 |
| French needed fix (*finit* → *fini*) | needed 0.83 | needed 1.00 |
| Missed error, no reference given (*its ready* left in place) | 0.57: unsure | 0.98 |
| Missed error against the reference answer, 4 cases | 0.93 / 0.02 / 0.13 / 0.83, all right | 1.00 / 0.00 / 0.00 / 1.00, all right |
| One Choice (needed fix, optional, harmful) instead of three yes/no | right label on all 8; 530 tokens | right label on all 8, less peaked; 289 tokens |
| Four changes in one request, questions pointing at `changes[i]` | drifts to 0.3–0.75 on easy changes | contradictory: *tmrw* → *tomorrow* needed 0.96 **and** harmful 0.92 |

What this says, on too few items to be more than a smoke test: the request shapes work as documented; Jev is about twice as fast and a third the price per token; Decisions is more decisive and deterministic; Jev is weaker when it has to find an error itself rather than compare against a reference; and both degrade when one state holds several changes. The probe scripts stayed in scratch space; [judge-prompting.md](judge-prompting.md) carries what they showed into the request design.
