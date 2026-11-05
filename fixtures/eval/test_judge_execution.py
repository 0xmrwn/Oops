"""Bounded judging concurrency and restart behavior, with no inference providers."""

import hashlib
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from evaluation.campaign import judge
from evaluation.judge_execution import run
from evaluation.records import ROOT, append, lines, read_json, write_json
from evaluation.tasks import collect
from test_pipeline import case, fixture, judgment


def many_cases(root, count=8):
    directory = fixture(root)
    cases = [case(f"c{i}") for i in range(count)]
    path = directory / "cases.jsonl"
    path.write_text("".join(json.dumps(c) + "\n" for c in cases))
    experiment = read_json(directory / "experiment.json")
    experiment["snapshots"]["cases.jsonl"] = hashlib.sha256(path.read_bytes()).hexdigest()
    write_json(directory / "experiment.json", experiment)
    result = directory / "results/api--a.jsonl"
    template = lines(result)[0]
    result.write_text("".join(json.dumps({**template, "case": c["id"], "attempt": 1}) + "\n" for c in cases))
    return directory, cases, [{**template, "case": c["id"], "attempt": 1} for c in cases]


class JudgeExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.rubric = read_json(ROOT / "rubric.json")

    def tearDown(self):
        self.temporary.cleanup()

    def test_six_sol_slots_and_independent_decisions_queue(self):
        directory, _, _ = many_cases(self.root)
        barrier, decisions_finished = threading.Barrier(6), threading.Event()
        mutex = threading.Lock()
        active, peak, calls = {"codex": 0, "decisions": 0}, {"codex": 0, "decisions": 0}, []

        def sol(task, _):
            with mutex:
                index = sum(engine == "codex" for engine, _ in calls)
                calls.append(("codex", task["key"]))
                active["codex"] += 1
                peak["codex"] = max(peak["codex"], active["codex"])
            try:
                if index < 6:
                    barrier.wait(timeout=5)
                    self.assertTrue(decisions_finished.wait(5), "Decisions must advance while all Sol slots wait")
                return judgment(task), {}
            finally:
                with mutex:
                    active["codex"] -= 1

        def decisions(task, _, key):
            self.assertEqual(key, "fake")
            with mutex:
                calls.append(("decisions", task["key"]))
                active["decisions"] += 1
                peak["decisions"] = max(peak["decisions"], active["decisions"])
                if sum(engine == "decisions" for engine, _ in calls) == 8:
                    decisions_finished.set()
                active["decisions"] -= 1
            return judgment(task), {}

        with (
            patch("evaluation.judges.api_key", return_value="fake"),
            patch("evaluation.judges.codex", side_effect=sol),
            patch("evaluation.judges.decisions", side_effect=decisions),
        ):
            result = judge(directory, self.rubric, execute=True, codex_workers=6, decisions_workers=1)
        self.assertEqual(peak, {"codex": 6, "decisions": 1})
        self.assertEqual(result["done"], 16)
        saved = lines(directory / "judgments.jsonl")
        self.assertEqual(len(saved), 16)
        self.assertEqual(len({(r["key"], r["judge"]) for r in saved}), 16)
        self.assertEqual(result["workers"], {"codex": 6, "decisions": 1})

    def test_resume_only_sends_missing_engine_results(self):
        directory, cases, records = many_cases(self.root)
        tasks = collect({c["id"]: c for c in cases}, records, self.rubric)
        known = next(iter(tasks.values()))
        append(
            directory / "judgments.jsonl",
            {
                "key": known["key"],
                "case": known["evidence"]["case"],
                "judge": "decisions",
                "status": "ok",
                "judgment": judgment(known),
            },
        )
        with (
            patch("evaluation.judges.api_key", return_value="fake"),
            patch("evaluation.judges.codex", side_effect=lambda t, _: (judgment(t), {})) as sol,
            patch("evaluation.judges.decisions", side_effect=lambda t, *_: (judgment(t), {})) as decisions,
        ):
            result = judge(directory, self.rubric, execute=True, codex_workers=6)
        self.assertEqual(sol.call_count, 8)
        self.assertEqual(decisions.call_count, 7)
        self.assertEqual(result["done"], 15)
        self.assertEqual(len(lines(directory / "judgments.jsonl")), 16)

    def test_invalid_worker_counts_fail_before_inference(self):
        directory, _, _ = many_cases(self.root)
        for settings in ({"codex_workers": 0}, {"decisions_workers": -1}):
            with self.assertRaisesRegex(ValueError, "workers must be positive"):
                judge(directory, self.rubric, execute=True, **settings)

    def test_stop_drains_inflight_results_without_starting_the_remaining_queue(self):
        directory, cases, records = many_cases(self.root)
        tasks = collect({c["id"]: c for c in cases}, records, self.rubric)
        pending = [(task, ["codex", "decisions"]) for task in tasks.values()]
        stop, barrier = threading.Event(), threading.Barrier(6)

        def sol(task, _):
            barrier.wait(timeout=5)
            stop.set()
            return judgment(task), {}

        def decisions(task, *_):
            self.assertTrue(stop.wait(5))
            return judgment(task), {}

        with (
            patch("evaluation.judges.codex", side_effect=sol),
            patch("evaluation.judges.decisions", side_effect=decisions),
        ):
            result = run(directory, self.rubric, pending, "fake", {"codex": 6, "decisions": 1}, stop)
        self.assertEqual(result["status"], "interrupted")
        self.assertIn(result["done"], (6, 7))
        self.assertTrue(all(x["active"] == 0 for x in result["by_judge"].values()))
        with (
            patch("evaluation.judges.api_key", return_value="fake"),
            patch("evaluation.judges.codex", side_effect=lambda t, _: (judgment(t), {})),
            patch("evaluation.judges.decisions", side_effect=lambda t, *_: (judgment(t), {})),
        ):
            resumed = judge(directory, self.rubric, execute=True, codex_workers=6)
        self.assertEqual(result["done"] + resumed["done"], 16)
        saved = lines(directory / "judgments.jsonl")
        self.assertEqual(len(saved), 16)
        self.assertEqual(len({(r["key"], r["judge"]) for r in saved}), 16)

    def test_repeated_engine_failures_stop_submissions_and_preserve_errors(self):
        directory, cases, records = many_cases(self.root, count=12)
        tasks = collect({c["id"]: c for c in cases}, records, self.rubric)
        pending = [(task, ["codex", "decisions"]) for task in tasks.values()]
        failed, mutex, count = threading.Event(), threading.Lock(), 0

        def sol(*_):
            nonlocal count
            with mutex:
                count += 1
                if count >= 6:
                    failed.set()
            raise ValueError("subscription unavailable")

        def decisions(task, *_):
            self.assertTrue(failed.wait(5))
            return judgment(task), {}

        with (
            patch("evaluation.judges.codex", side_effect=sol),
            patch("evaluation.judges.decisions", side_effect=decisions),
        ):
            result = run(directory, self.rubric, pending, "fake", {"codex": 6, "decisions": 1})
        self.assertEqual(result["status"], "partial")
        self.assertIn("Six consecutive codex failures", result["stop_reason"])
        self.assertGreaterEqual(result["errors"], 6)
        self.assertLessEqual(count, 11)
        self.assertEqual(len(lines(directory / "judgments.jsonl")), result["done"])

    def test_existing_writer_is_rejected_before_planning_or_inference(self):
        from evaluation.records import lock

        directory, _, _ = many_cases(self.root)
        with lock(directory / ".judging.lock"), patch("evaluation.campaign.collect") as collect_mock:
            with self.assertRaisesRegex(ValueError, "Another judge process"):
                judge(directory, self.rubric, execute=True, codex_workers=6)
            collect_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
