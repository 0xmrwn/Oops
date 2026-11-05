# Oops Eval dashboard

From the checkout, run `just eval-dashboard` or
`python3 fixtures/eval/manage.py serve --port 8766`. Open the printed loopback URL.
Use `--runs DIR` to select a separate run store. Stop the server with Ctrl-C.

The dashboard reads the same scoring pipeline as `manage.py score`; it does not
compute a separate quality score. It shows generation and judging progress,
coverage, matched comparisons, timing, reliability and unresolved judgments.
Select a case to inspect its edits and save a blind owner judgment. Model identity
is hidden during review. Agent annotations and human labels retain their source.

The server can read reports and save judgments only. It has no inference endpoint.
Run directories may contain full drafts and outputs and stay outside Git. The
server rejects requests from other hosts/origins and binds only to `127.0.0.1`.
See [the CLI reference](../../../docs/eval.md) and
[How answers are scored](../../../docs/eval.md#how-answers-are-scored) for commands and metrics.

`just eval-test` covers report/review persistence and the HTTP boundary with
synthetic temporary runs and stubbed judges.
