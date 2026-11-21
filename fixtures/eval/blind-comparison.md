# Blind local Fix comparison

Protocol `blind-fix-v2` uses one first attempt on the same frozen cases for stock and tuned Qwen and Liquid, Luna, Haiku, Mac autocorrect, the Apple on-device model and Writing Tools Proofread. Reviewers answer “Would I send this draft as-is?” on the text Oops would leave in the editor. The two hosted comparisons each have a three-percentage-point noninferiority margin. Each native comparison requires superiority. Existing `blind-fix-v1` runs use their original language coverage rules.

## Freeze before generation

Reuse the [OopsEval run snapshot](README.md#experiment-snapshot). Prepare reviewed cases with the full active system prompt in `instructions` when it differs from the app default. Supply primary language, family and split. Keep preference variants and revisions together before dividing families between training and evaluation. Include both English (`en`) and French (`fr`) in the qualification corpus. Use held-out real messages for qualification and the existing development fixtures for rehearsal. Keep the natural language and length mix in the real test. Treat missing layout tags as unknown.

Keep predominantly French drafts under `fr` when they contain deliberate English terms. During review, list each distinct term or phrase verbatim under `tags.english_terms` when it should survive Fix. For example, annotate `laptop` in “J’ai oublie mon laptop” with “J’ai oublié mon laptop” as the reference. Include the same terms in any accepted alternative. Use the drafts that occur naturally, with no minimum count or quota for annotations.

Add a `comparison` object to the lane config before the first call. Pin exact model/checkpoint identifiers and quantizations in the lane config; assign distinct model aliases to stock and tuned endpoints. Use the same frozen sampling settings and production correction contract. Record the OS build and settings of the native comparators. The example names below illustrate result filenames; use the actual filenames for each configured lane.

```json
{
  "protocol": "blind-fix-v2",
  "purpose": "qualification",
  "rubric_sha256": "<canonical rubric digest>",
  "shortcut_cases": {"<cold case id>": "cold", "<warm case id>": "warm"},
  "lanes": {
    "qwen-stock": "results/api--qwen-stock.jsonl",
    "qwen-tuned": "results/api--qwen-tuned.jsonl",
    "liquid-stock": "results/api--liquid-stock.jsonl",
    "liquid-tuned": "results/api--liquid-tuned.jsonl",
    "luna": "results/chatgpt--luna.jsonl",
    "haiku": "results/claude--haiku.jsonl",
    "autocorrect": "results/editor--autocorrect.jsonl",
    "apple-model": "results/editor--apple-model.jsonl",
    "proofread": "results/editor--proofread.jsonl"
  }
}
```

For qualification, also add a `models` map under `comparison` with the same nine role names and their exact resolved model identifiers or native build identifiers. The report checks each against its result lane. Use `purpose: fixture` for rehearsals. From `fixtures/eval`, get an identity with `python3 -c 'import sys; from evaluation.records import digest,read_json; print(digest(read_json(sys.argv[1])))' rubric.json`. The same command on the run's `experiment.json` gives the identity for editor observations.

Run `oops-eval lanes` with the comparison config, corpus and `--attempts 1`. Retain terminal errors and timeouts. Keep provider refusals and guard rejections visible. For native or isolated editor lanes, collect one observation per case with `experiment` (digest), `role`, exact `model` or build, `case`, `output` (editor result), `raw` (JSON correction envelope when available), OopsEval `checks` and `error`. On failure, record a null output and the error. A valid native no-change decision returns the original draft. Import a complete JSONL lane with `manage.py compare-import --run NAME --role ROLE --observations FILE`. Changed observations require a fresh run.

## Record shortcut timing

Use the isolated M3 lab and the same registered case schedule for both local students. Include cold loads and warm drafts of 1–30 whitespace-delimited words. Start a cold trial with model weights unloaded. For warm trials keep them resident. Start the clock at the triggering key-down and stop when the editor shows the applied text or when Oops signals clear or terminal failure for that invocation.

The lab can use `evaluation.shortcut.measure(press, wait_for_editor, state, peak_rss_bytes, download_bytes)`. The press helper returns the monotonic key-down timestamp in nanoseconds. The observer must wait for the matching editor outcome, including a bounded timeout. Measure peak resident memory for the same local serving processes and the bytes of the downloadable model artifacts. Write each returned observation with `experiment`, `role` and `case` into the run's `shortcut.jsonl`. Provider response times are a different clock. Report cold samples, warm short p95, successful results within one second, peak memory and download size.

## Review and score

Open `manage.py serve --runs DIR` and select the comparison run. The comparison view removes model identity, timing, automated verdicts and output provenance. Identical answers for the same case are presented once. The human sees the original, editing instructions, references and diff. Raw and applied outputs that differ are separate anonymous answers. Decisions remains available for separate screening. Only explicit blind human yes/no votes enter the headline. A generation failure scores zero; a missing attempt or an unfinished review makes that pair inconclusive.

Run `manage.py compare --runs DIR --run NAME`. Each source family gets equal weight; average its paired draft differences before estimating the population difference. The two-sided 95% interval uses the tighter of Hoeffding and empirical Bernstein bounds with the error budget split between them. This conservative choice keeps identical outcomes on a small sample inconclusive. The intervals are per comparison. Require the lower bound to reach −0.03 against each hosted model and exceed zero against each native baseline. The report also compares each tuned student with its stock checkpoint.

Report harmful edits, exact clean preservation, protected-span failures before and after reconciliation, both sides of each preference group, and counts by language, known layout and error type. Qualification also requires at least 99% successful unchanged clean drafts, zero applied protected-span violations, complete timing coverage, warm short p95 below one second and at least 95% successful within one second. The clean percentage is descriptive; report the clean denominator. Fixture runs can only rehearse the protocol.

Each lane’s `english_term_preservation` reports the number of annotated French drafts and term occurrences, then counts preserved, changed and unavailable occurrences independently in raw and applied text. Matching is case-sensitive and uses word boundaries, so a longer word cannot stand in for the original term. Each original occurrence counts separately. Missing attempts, terminal failures without applied text and native lanes without raw output remain visible as unavailable. With no annotations the denominator is zero. This is a descriptive measure alongside the family-weighted blind votes.

Run `just eval-test` to exercise the nine-role matrix, preference pairs, import, anonymization, failure accounting and paired decisions with repository fixtures.
