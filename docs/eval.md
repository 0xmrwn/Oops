# Evaluation CLI reference

`oops-eval` runs text cases through Oops's correction prompt, provider adapters,
decoding and validation. It does not drive editors or test Accessibility behavior.

## Build and try it offline

From the checkout, using the toolchain in the [README](../README.md#build):

```sh
swift build --product oops-eval
.build/debug/oops-eval --help
mkdir -p .build/eval-example
.build/debug/oops-eval run --corpus fixtures/corpus/stress.jsonl \
  --provider echo --out .build/eval-example/echo.jsonl
```

`echo` returns the input unchanged without a model call. It checks the corpus and
result-writing path; it is not a correction-quality test.

## Cases and single-provider runs

Case files are UTF-8 JSON Lines, one object per line. Each case needs an `id`,
`input` and `label`. For example:

```json
{"id":"example-1","input":"fix teh typo","expected":"fix the typo","label":"accepted"}
```

Labels are `accepted`, `clear`, `rejected` and `invalid`. Use `expected` for a known
answer, or `rejected` for an answer known to be wrong. Without an expected answer,
a valid result can be unscored. See [Corpus.swift](../Sources/OopsEval/Corpus.swift)
for the optional metadata fields.

`run` accepts `echo`, `api`, `claude` or `chatgpt` as its provider. For an
OpenAI-compatible Chat Completions endpoint, supply `--base-url`, `--model` and,
when authentication is required, `--key-env NAME`. The latter reads the key from
the named environment variable. Claude uses the installed, signed-in Claude Code
CLI. ChatGPT uses the sign-in saved by Oops and may prompt for Keychain access.

`--rules FILE` replaces the correction instructions while retaining the output
contract. `--jobs N` controls concurrent calls. `--out FILE` writes per-case JSONL;
the summary goes to stdout, with `--json` available for scripts.

Provider runs send case text to the configured provider and can incur charges or
use subscription quotas. Corpus files and results can contain full drafts and
model responses. Keep private data and credentials out of Git.

## Multiple models

`lanes` runs the providers and models listed in a JSON configuration. The default
is `fixtures/eval/lanes.json`; use `--config FILE` for your own. Configure provider
URLs, model IDs, environment variable names and pacing for your accounts. The
configuration types are in [Lanes.swift](../Sources/OopsEval/Lanes.swift).

Inspect the plan before sending corrections:

```sh
.build/debug/oops-eval lanes --cases fixtures/corpus/stress.jsonl \
  --run example --attempts 1 --limit 2 --env-file .env --dry-run
```

`--dry-run` skips correction calls. Resolving Claude or ChatGPT models can still
contact their services or request Keychain access, and it writes no run files.
Remove `--dry-run` to execute the plan. `--only` filters by provider name
or configured model ID, comma-separated. `--env-file` loads only the environment
variables named by the configuration; the selected file takes priority over
ambient values.

Results go under `~/Library/Application Support/oops-eval/runs/<run>/`, or the
directory supplied with `--runs`. Each run has `experiment.json`, frozen case,
configuration and price snapshots, `manifest.json` and one JSONL file
per lane/model under `results/`. Records include the case and attempt, resolved
model, request format, timing, token usage, output, verdict and validation checks.
Fields that cannot be measured are null.

Rerunning the same run first verifies its frozen identity, then skips recorded
case/attempt pairs. The identity includes source revision/bytes, executable, prompt,
corpus, configuration, prices, attempts and limit. Missing or altered snapshots,
legacy runs without an identity, and resolved model/effort drift are refused.
A generator lock prevents concurrent writers. Use a new run name when changing
that identity. Preserve the original checkout and executable for an earlier
experiment; a current build cannot resume it. `--retry-errors` resends error records;
`--retry-deferred` lifts a quota deferral. Both can send additional requests.
Pacing and retry limits come from the configuration and provider responses.

```sh
.build/debug/oops-eval report --run example
.build/debug/oops-eval report --run example --json
```

Reports show validity, verdict counts, p50/p95 latency, errors and rate limits.
Validity means the answer passed the correction checks; it does not establish
that every edit was correct. Cost estimates use the configured price table when
available. They are not billing records.

## Judging and the local dashboard

The Python companion reads immutable generation results and attaches versioned
judgments. It uses only the standard library. Planning and scoring are offline:

```sh
python3 fixtures/eval/manage.py judge --run example
python3 fixtures/eval/manage.py score --run example --out .build/eval-report.json
python3 fixtures/eval/manage.py calibrate --run example
just eval-dashboard
```

`judge` sends requests only with `--execute`. It uses Decisions with the selected
project API key and Codex/Sol with ChatGPT subscription authentication:

```sh
python3 fixtures/eval/manage.py judge --run example --execute --env-file .env \
  --codex-workers 6 --decisions-workers 1
```

Successful reviews are cached by evidence and protocol. Judges receive no generator
identity. Worker counts affect scheduling; they do not change the rubric or cache
identity. Agent labels remain distinct from human labels. See
[How answers are scored](#how-answers-are-scored) for verdicts, denominators and uncertainty.

The dashboard binds to the printed loopback URL. It reads scores and saves blind
owner judgments; it cannot launch inference. Stop it with Ctrl-C. Keep private
run data, held cases and real drafts outside the repository. Only the 150 reviewed
synthetic development cases are tracked. The 50 held cases are required locally
for `manage.py prepare`; `--dev-only` prepares just the public development set.

`just eval-test` runs deterministic Python tests without model calls. `just check`
runs them when evaluation implementation, tests, rubric or dataset files change.

## How answers are scored

- A necessary, valid edit earns a true positive. Optional changes earn none and count as excess
  edits in minimal-edit precision; harmful changes also count against precision and have their own
  harm rate.
- Judgments are reference-guided, so a missed error counts even when nothing changed, and a valid
  alternative correction can satisfy the reference. Related edits are aligned together rather than
  parsed with an English-only grammar tool. This F0.5 is custom, not an ERRANT score.
- A reviewed clean draft passes unchanged or as one of its approved alternatives, whose changes are
  optional. A dirty draft's approved reference shows what is acceptable, not which edits were
  necessary: changed and unchanged answers both need judging, and matching the reference exactly
  earns no true positives by itself.
- An answer is accepted automatically only against a reviewed reference; one without a reference
  needs review. Uncertainty never silently becomes a pass. Judgments stay provisional: the rubric's
  0.9/0.1 thresholds are not accuracy probabilities.
- Fully-correct rates count failed and invalid calls as failures. Edit metrics apply to resolved
  answers; read them with coverage, failure rate and harm, never alone.
- The table shows each lane's own coverage. The plot uses only case–attempt pairs graded in every
  eligible lane. Intervals resample case families, keeping repeated calls together. Origin,
  language, length, split and error type each get a breakdown; none is a population claim.
- `pass_all` is the share of fully graded cases that succeeded on every configured attempt, and
  `pass2` its two-attempt form; `flip_rate` measures mixed outcomes on those cases. Unresolved or
  unfinished repeats never count as consistent successes.
- Costs are list-price estimates, not invoices: free quotas and credits aren't subtracted, and
  cache writes are missing when a provider doesn't report usage. Subscription lanes have no
  marginal API cost per success.
- `calibrate` reports each judge and the aggregation separately: errors, abstentions, false
  acceptances and where each reference came from.

## Other commands

- `export` builds a corpus from the local diagnostic log. `--redact` replaces
  email addresses and long digit runs; it does not remove all personal data.
- `replay` decodes saved answers with the current correction rules without a
  model call. Supply `--answers FILE` for a result file or `--log DIR` for logs.
- `finetune` writes chat-format training examples from cases with known answers.
  It does not upload them or start a training job.

Run `oops-eval --help` for arguments and defaults.
