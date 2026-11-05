#!/usr/bin/env python3
"""Local companion to oops-eval lanes: corpus, judges, scores and dashboard."""

import argparse
import json
import sys
from pathlib import Path

from evaluation.calibration import prepare_calibration
from evaluation.campaign import calibrate, judge, prepare
from evaluation.records import DEFAULT_RUNS, ROOT, read_json, run_directory, write_json
from evaluation.scoring import report
from evaluation.server import serve
from evaluation.tasks import schema


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, epilog="No command starts generation. Judging is a dry plan unless --execute is supplied."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser(
        "schema", help="Print the judge and human-review JSON schema; no local run or credentials needed."
    )
    dataset = commands.add_parser(
        "prepare", help="Verify the reviewed freeze and assemble a private corpus; no model calls."
    )
    dataset.add_argument("--dev", type=Path, default=ROOT / "cases.jsonl")
    dataset.add_argument(
        "--held", type=Path, default=Path.home() / "Library/Application Support/oops-eval/held-back/cases.jsonl"
    )
    dataset.add_argument("--out", type=Path, required=True)
    dataset.add_argument("--dev-only", action="store_true")
    panel = commands.add_parser(
        "prepare-calibration", help="Freeze existing synthetic outputs plus marked authored examples; no inference."
    )
    panel.add_argument("--runs", type=Path, default=DEFAULT_RUNS)
    panel.add_argument("--run", required=True, help="Original source run; held-back and private cases are excluded.")
    panel.add_argument("--out-runs", type=Path, help="Destination runs directory; defaults to --runs.")
    panel.add_argument("--out-run", required=True, help="New calibration-only run name.")
    panel.add_argument("--limit", type=int, default=30, help="Maximum imported/authored records (default: 30).")
    grading = commands.add_parser(
        "judge", help="Plan resumable Decisions and subscription Codex judging; --execute sends requests."
    )
    grading.add_argument("--judge", choices=("both", "decisions", "codex"), default="both")
    grading.add_argument(
        "--execute", action="store_true", help="Actually call the selected judges (never starts correction generation)."
    )
    grading.add_argument("--limit", type=int)
    grading.add_argument(
        "--codex-workers", type=int, default=1, help="Concurrent subscription Codex/Sol reviews (default: 1)."
    )
    grading.add_argument(
        "--decisions-workers", type=int, default=1, help="Independent Decisions queue workers (default: 1)."
    )
    grading.add_argument(
        "--judge-split",
        choices=("development", "validation"),
        help="Keep judge development separate from final validation by case family.",
    )
    grading.add_argument(
        "--env-file", type=Path, help="Selected project env file; only OPENAI_API_KEY is read, never passed to Codex."
    )
    grading.add_argument(
        "--include-anchors", action="store_true", help="Also judge code-scored answers, for calibration and audits."
    )
    scoring = commands.add_parser(
        "score", help="Compute a report from immutable outputs and saved judgments; no network."
    )
    scoring.add_argument("--out", type=Path)
    calibration = commands.add_parser(
        "calibrate",
        help="Compare judges with source-attributed reference labels; never approves a judge automatically.",
    )
    for command in (grading, scoring, calibration):
        command.add_argument("--runs", type=Path, default=DEFAULT_RUNS)
        command.add_argument("--run", required=True)
        command.add_argument("--rubric", type=Path, default=ROOT / "rubric.json")
    website = commands.add_parser(
        "serve", help="Open the local results/review server. No inference controls exist in the website."
    )
    website.add_argument("--runs", type=Path, default=DEFAULT_RUNS)
    website.add_argument("--port", type=int, default=8766)
    arguments = sys.argv[1:]
    if arguments and arguments[0] == "help":
        arguments = arguments[1:] + ["--help"]
    args = parser.parse_args(arguments)
    try:
        if args.command == "schema":
            result = {"schema_version": 1, "judgment": schema()}
        elif args.command == "prepare":
            result = prepare(args.dev, args.held, args.out, args.dev_only)
        elif args.command == "prepare-calibration":
            result = prepare_calibration(
                run_directory(args.runs, args.run), args.out_runs or args.runs, args.out_run, args.limit
            )
        elif args.command == "serve":
            serve(args.runs.expanduser().resolve(), args.port)
            return 0
        else:
            directory, rubric = run_directory(args.runs, args.run), read_json(args.rubric)
            if args.command == "judge":
                if args.limit is not None and args.limit <= 0:
                    raise ValueError("--limit must be positive.")
                result = judge(
                    directory,
                    rubric,
                    args.judge,
                    args.execute,
                    args.limit,
                    args.env_file,
                    args.include_anchors,
                    args.judge_split,
                    args.codex_workers,
                    args.decisions_workers,
                )
            elif args.command == "calibrate":
                result = calibrate(directory, rubric)
            else:
                result = report(directory, rubric)
                if args.out:
                    write_json(args.out, result)
        print(json.dumps({"ok": True, "data": result}, ensure_ascii=False, indent=2))
        return 4 if result.get("status") == "partial" else 0
    except KeyboardInterrupt:
        print(
            json.dumps(
                {"ok": False, "error": {"code": "INTERRUPTED", "message": "Stopped; saved records can be resumed."}}
            ),
            file=sys.stderr,
        )
        return 130
    except (ValueError, OSError, KeyError, TypeError) as error:
        message = (
            str(error)
            if isinstance(error, ValueError)
            else "Required local data could not be read. Check the run and file paths."
        )
        print(
            json.dumps({"ok": False, "error": {"code": "EVAL_INPUT_OR_PROVIDER", "message": message}}), file=sys.stderr
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
