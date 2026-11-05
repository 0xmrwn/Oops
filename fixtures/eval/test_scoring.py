"""Scoring policy and raw evidence regressions, exercised without inference."""

import json
import tempfile
import unittest
from pathlib import Path

from evaluation.campaign import calibrate, save_label
from evaluation.records import ROOT, append, lines, read_json
from evaluation.scoring import aggregate, case_detail, report, select
from evaluation.tasks import code_judgment, task_for
from test_pipeline import fixture, judgment


class ScoringTests(unittest.TestCase):
    def test_eta_session_counts_exclude_outputs_from_before_a_resume(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = fixture(Path(temporary))
            path = directory / "manifest.json"
            manifest = read_json(path)
            manifest["sessions"] = [{"started": "2026-11-03T01:00:00.500Z"}]
            path.write_text(json.dumps(manifest))
            results = directory / "results/api--a.jsonl"
            rows = lines(results)
            rows[0]["started"] = "2026-11-03T01:00:00.499Z"
            rows[1]["started"] = "2026-11-03T01:00:00.501Z"
            results.write_text("".join(json.dumps(row) + "\n" for row in rows))
            lane = report(directory)["lanes"][0]
            self.assertEqual(lane["session_calls"], 1)
            self.assertEqual(lane["metrics"]["calls"], 2)

    def test_reviewed_clean_alternative_does_not_earn_correction_credit(self):
        case = next(c for c in lines(ROOT / "cases.jsonl") if c["id"] == "en-s-039")
        task = task_for(case, case["alternatives"][0], read_json(ROOT / "rubric.json"))
        selected = code_judgment(task)
        measured = aggregate(
            [({"case": case["id"], "output": task["evidence"]["corrected"]}, selected, "code")], {case["id"]: case}
        )
        self.assertEqual(measured["correct"], 1)
        self.assertEqual(measured["needed"], 0)
        self.assertGreater(measured["optional"], 0)
        self.assertEqual(measured["f05"], 0)

    def test_raw_answers_can_be_reviewed_when_reconciled_or_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = fixture(Path(temporary))
            path = directory / "results/api--a.jsonl"
            rows = lines(path)
            rows[0]["raw"] = json.dumps({"text": "the feline is here"})
            rows[1].update(output=None, raw=json.dumps({"text": "the dog is here"}), verdict="invalid")
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            rubric = read_json(ROOT / "rubric.json")
            detail = case_detail(directory, "c", rubric)
            for answer in detail["answers"]:
                self.assertIn("raw_task", answer)
                task = answer["raw_task"]
                save_label(directory, task["key"], judgment(task), rubric)
            reloaded = case_detail(directory, "c", rubric)
            self.assertTrue(all(a["raw_source"] == "human" for a in reloaded["answers"]))
            self.assertIsNone(reloaded["answers"][1]["task"])
            self.assertNotEqual(reloaded["answers"][0]["raw_task"]["key"], reloaded["answers"][1]["raw_task"]["key"])

    def test_agent_reference_labels_keep_provenance_and_humans_override_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = fixture(Path(temporary), "the feline is here")
            rubric = read_json(ROOT / "rubric.json")
            task = case_detail(directory, "c", rubric)["answers"][0]["task"]
            label = judgment(task)
            saved = save_label(directory, task["key"], label, rubric, author="agent")
            self.assertEqual(case_detail(directory, "c", rubric)["answers"][0]["source"], "agent")
            self.assertEqual(lines(directory / "labels.jsonl")[0]["annotator"]["kind"], "agent")
            append(
                directory / "judgments.jsonl", {"key": task["key"], "judge": "codex", "status": "ok", "judgment": label}
            )
            measured = calibrate(directory, rubric)
            panel = measured["panels"][saved["judge_split"]]["codex"]
            self.assertEqual(panel["reference_sources"], {"agent": 1})
            self.assertEqual(panel["human_labels"], {})
            self.assertEqual(panel["reference_labels"], {"yes": 1})
            self.assertEqual(measured["reference_sources"], {"agent": 1})
            save_label(directory, task["key"], label, rubric)
            self.assertEqual(case_detail(directory, "c", rubric)["answers"][0]["source"], "human")
            self.assertEqual(calibrate(directory, rubric)["reference_sources"], {"human": 1})

    def test_reference_labels_survive_judge_tuning_but_not_policy_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = fixture(Path(temporary), "the feline is here")
            rubric = read_json(ROOT / "rubric.json")
            task = case_detail(directory, "c", rubric)["answers"][0]["task"]
            label = judgment(task)
            save_label(directory, task["key"], label, rubric, author="agent")
            append(
                directory / "judgments.jsonl", {"key": task["key"], "judge": "codex", "status": "ok", "judgment": label}
            )
            tuned = {**rubric, "high": 0.95, "codex_effort": "medium"}
            changed = case_detail(directory, "c", tuned)["answers"][0]
            self.assertNotEqual(changed["task"]["key"], task["key"])
            self.assertEqual(changed["source"], "agent")
            self.assertNotIn("codex", changed["judges"])
            policy_change = case_detail(directory, "c", {**rubric, "policy": "Different policy"})["answers"][0]
            self.assertNotIn("agent", policy_change["judges"])

    def test_sol_can_resolve_abstentions_but_not_confident_conflicts(self):
        task = task_for(
            {"id": "c", "input": "teh cat", "expected": "the cat"}, "the feline", read_json(ROOT / "rubric.json")
        )
        sol = judgment(task)
        fast = judgment(task, "uncertain", "uncertain")
        rows = {"codex": {"judgment": sol}, "decisions": {"judgment": fast}}
        self.assertEqual(select(task, rows), (sol, "sol_escalation"))
        fast["edits"][0]["verdict"] = "optional"
        self.assertEqual(select(task, rows), (None, "disagreement"))
        self.assertEqual(select(task, {"codex": rows["codex"]}), (None, "pending"))

    def test_unreferenced_answers_need_explicit_review_before_passing(self):
        task = task_for({"id": "c", "input": "teh cat"}, "the cat", read_json(ROOT / "rubric.json"))
        label = judgment(task)
        rows = {"codex": {"judgment": label}, "decisions": {"judgment": label}}
        self.assertEqual(select(task, rows), (None, "reference_required"))
        rows["decisions"] = {"judgment": judgment(task, "uncertain", "uncertain")}
        self.assertEqual(select(task, rows), (None, "reference_required"))
        rows["agent"] = {"judgment": label}
        self.assertEqual(select(task, rows), (label, "agent"))


if __name__ == "__main__":
    unittest.main()
