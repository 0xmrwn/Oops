"""Offline contract checks. No real providers or owner credentials are used."""

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from evaluation.alignment import edits, optional_capital_accent
from evaluation.campaign import judge, save_label, validate_cases
from evaluation.judges import codex, decisions, probabilities
from evaluation.records import ROOT, append, load_run, read_json, run_directory, write_json
from evaluation.scoring import case_detail, report, select
from evaluation.tasks import code_judgment, collect, task_for, validate


def case(identifier="c", **changes):
    return {
        "id": identifier,
        "input": "teh cat is here",
        "expected": "the cat is here",
        "label": "accepted",
        "lang": "en",
        "split": "dev",
        "origin": "synthetic",
        "length": "xs",
        "tags": {"clean": False, "errors": ["typo"]},
        **changes,
    }


def judgment(task, verdict="needed", fully="yes"):
    return {
        "edits": [{"id": e["id"], "verdict": verdict, "explanation": "test"} for e in task["evidence"]["edits"]],
        "misses": [
            {"id": e["id"], "verdict": "satisfied", "explanation": "test"} for e in task["evidence"]["reference_edits"]
        ],
        "fully_correct": fully,
        "faithful": "yes",
        "explanation": "test",
    }


def fixture(root, output="the cat is here", two_lanes=False):
    directory = root / "offline-test"
    directory.mkdir()
    c = case()
    (directory / "cases.jsonl").write_text(json.dumps(c) + "\n")
    write_json(directory / "config.json", {"attempts": 2, "providers": []})
    write_json(
        directory / "experiment.json",
        {
            "schema_version": 2,
            "attempts": 2,
            "prompt": "unchanged",
            "prompt_sha256": "test",
            "snapshots": {
                name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
                for name in ("cases.jsonl", "config.json")
            },
        },
    )
    manifest = {"run": directory.name, "cases": str(directory / "cases.jsonl"), "attempts": 2, "lanes": []}
    for name in ["a", "b"] if two_lanes else ["a"]:
        file = f"results/api--{name}.jsonl"
        manifest["lanes"].append(
            {"file": file, "provider": name, "lane": "api", "resolved": name, "model": name, "state": "done"}
        )
        for attempt in (1, 2):
            if name == "b" and attempt == 2:
                continue
            append(
                directory / file,
                {
                    "case": "c",
                    "attempt": attempt,
                    "output": output,
                    "raw": json.dumps({"text": output}),
                    "verdict": "changed",
                    "total_ms": 100,
                    "elapsed_ms": 250,
                    "provider": name,
                    "model": name,
                    "lane": "api",
                    "cost_usd": 0.01,
                    "checks": {"valid": True},
                },
            )
    write_json(directory / "manifest.json", manifest)
    return directory


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.rubric = read_json(ROOT / "rubric.json")

    def tearDown(self):
        self.temp.cleanup()

    def test_alignment_preserves_unicode_offsets_and_groups_related_edits(self):
        source = "🙂 teh café est ici\r\n"
        target = "🙂 the café est ici\r\n"
        changes = edits(source, target)
        self.assertEqual(len(changes), 1)
        e = changes[0]
        self.assertEqual(source[: e["start"]] + e["after"] + source[e["end"] :], target)
        self.assertTrue(optional_capital_accent(edits("Etat", "État")[0], "fr"))
        self.assertFalse(optional_capital_accent(edits("État", "Etat")[0], "fr"))

    def test_code_uses_alternatives_and_does_not_reward_doing_nothing(self):
        c = case(alternatives=["the cat's here"])
        self.assertIsNone(code_judgment(task_for(c, "the cat's here", self.rubric)))
        clean = case(input="this is fine", expected="this is fine", alternatives=["This is fine"])
        alternative = code_judgment(task_for(clean, "This is fine", self.rubric))
        self.assertEqual(alternative["fully_correct"], "yes")
        self.assertEqual(alternative["edits"][0]["verdict"], "optional")
        missed = code_judgment(task_for(c, c["input"], self.rubric))
        self.assertIsNone(missed)

    def test_key_changes_with_policy_reference_and_output(self):
        c = case()
        original = task_for(c, "other", self.rubric)["key"]
        self.assertNotEqual(original, task_for(c, "changed", self.rubric)["key"])
        self.assertNotEqual(original, task_for(c, "other", {**self.rubric, "policy": "new"})["key"])
        self.assertNotEqual(original, task_for({**c, "expected": "other"}, "other", self.rubric)["key"])

    def test_duplicate_answers_share_work_and_dry_plan_never_calls_judges(self):
        directory = fixture(self.root, "the feline is here")
        with (
            patch("evaluation.judges.codex", side_effect=AssertionError("network")),
            patch("evaluation.judges.decisions", side_effect=AssertionError("network")),
        ):
            plan = judge(directory, self.rubric)
        self.assertEqual(plan["pending_answers"], 1)
        self.assertEqual(plan["judge_calls"], 2)
        self.assertFalse((directory / "judgments.jsonl").exists())
        split_counts = [
            judge(directory, self.rubric, judge_split=split)["judge_calls"] for split in ("development", "validation")
        ]
        self.assertEqual(sum(split_counts), plan["judge_calls"])
        self.assertIn(0, split_counts)

    def test_pipeline_resumes_and_leaves_disagreement_unresolved(self):
        directory = fixture(self.root, "the feline is here")
        _, _, cases, records = load_run(directory)
        task = next(iter(collect(cases, records, self.rubric).values()))
        a, b = judgment(task), judgment(task, "optional")
        with (
            patch("evaluation.judges.api_key", return_value="fake"),
            patch("evaluation.judges.decisions", return_value=(a, {})),
            patch("evaluation.judges.codex", return_value=(b, {})),
        ):
            result = judge(directory, self.rubric, execute=True)
        self.assertEqual(result["done"], 2)
        self.assertEqual(judge(directory, self.rubric)["judge_calls"], 0)
        measured = report(directory, self.rubric)
        self.assertEqual(measured["lanes"][0]["metrics"]["unresolved"], 2)
        save_label(directory, task["key"], a, self.rubric)
        self.assertEqual(report(directory, self.rubric)["lanes"][0]["metrics"]["correct"], 2)
        self.assertEqual(case_detail(directory, "c", self.rubric)["answers"][0]["source"], "human")

    def test_partial_lanes_compare_only_common_attempts(self):
        directory = fixture(self.root, two_lanes=True)
        task = case_detail(directory, "c", self.rubric)["answers"][0]["task"]
        save_label(directory, task["key"], judgment(task), self.rubric)
        measured = report(directory, self.rubric)
        self.assertEqual(measured["comparison_calls"], 1)
        self.assertEqual([lane["comparison"]["calls"] for lane in measured["lanes"]], [1, 1])
        self.assertEqual(measured["lanes"][0]["metrics"]["wait_p50_ms"], 250)
        self.assertEqual(measured["lanes"][0]["metrics"]["pass2"], 1)

    def test_real_and_derived_families_do_not_leak_across_splits(self):
        with self.assertRaisesRegex(ValueError, "family crosses"):
            validate_cases(
                [case("a", origin="real", family="x"), case("b", origin="derived", family="x", split="held")]
            )
        with self.assertRaisesRegex(ValueError, "family identifier"):
            validate_cases([case(origin="derived")])
        with self.assertRaises(ValueError):
            run_directory(self.root, "../escape")

    def test_subscription_list_value_is_not_reported_as_marginal_api_spend(self):
        directory = fixture(self.root)
        file = directory / "results/api--a.jsonl"
        rows = [json.loads(line) for line in file.read_text().splitlines()]
        for row in rows:
            row["lane"] = "chatgpt"
        file.write_text("".join(json.dumps(row) + "\n" for row in rows))
        manifest = read_json(directory / "manifest.json")
        manifest["lanes"][0]["lane"] = "chatgpt"
        write_json(directory / "manifest.json", manifest)
        measured = report(directory, self.rubric)["lanes"][0]["metrics"]
        self.assertIsNone(measured["cost_per_success_usd"])
        self.assertIsNone(measured["cost_usd"])
        self.assertEqual(measured["list_value_usd"], 0.02)

    def test_judging_refuses_private_or_unmarked_origins_before_calling_a_provider(self):
        directory = fixture(self.root)
        file = directory / "cases.jsonl"
        file.write_text(json.dumps(case(origin="real")) + "\n")
        experiment = read_json(directory / "experiment.json")
        experiment["snapshots"]["cases.jsonl"] = hashlib.sha256(file.read_bytes()).hexdigest()
        write_json(directory / "experiment.json", experiment)
        with patch("evaluation.judges.codex", side_effect=AssertionError("provider called")):
            with self.assertRaisesRegex(ValueError, "private"):
                judge(directory, self.rubric, chosen="codex", execute=True)

    def test_refusals_missing_edits_and_contradictions_are_not_successes(self):
        task = task_for(case(), "the feline is here", self.rubric)
        bad = judgment(task)
        bad["edits"] = []
        with self.assertRaises(ValueError):
            validate(bad, task)
        with self.assertRaises(ValueError):
            probabilities({"answers": [{"type": "refusal", "name": "x"}]}, ["x"])
        with self.assertRaises(ValueError):
            validate(judgment(task, "harmful", "yes"), task)
        self.assertEqual(select(task, {})[1], "pending")

    def test_decisions_requests_keep_evidence_separate_and_validate_probabilities(self):
        task = task_for(case(), "the feline is here", self.rubric)
        requests = []

        def post(body, key):
            self.assertEqual(key, "fake")
            requests.append(body)

            def answer(q):
                if q["type"] == "predicate":
                    return {"type": "predicate", "name": q["name"], "probability": 1}
                verdict = "satisfied" if q["name"].startswith("misses_") else "needed"
                return {
                    "type": "choice",
                    "name": q["name"],
                    "choice": verdict,
                    "confidence": 0.99,
                    "probabilities": [
                        {"value": c["value"], "probability": 1 if c["value"] == verdict else 0} for c in q["choices"]
                    ],
                }

            return {
                "model": "gpt-6-luna",
                "answers": [answer(q) for q in body["questions"]],
            }

        result, metadata = decisions(task, self.rubric, "fake", post)
        self.assertEqual(result["fully_correct"], "yes")
        self.assertEqual(metadata["requests"], len(requests))
        self.assertEqual(requests[0]["input"][0]["content"][0]["type"], "input_json")

    def test_codex_adapter_strips_api_credentials_and_isolates_its_home(self):
        home = self.root / "original-home"
        home.mkdir()
        (home / "auth.json").write_text(json.dumps({"auth_mode": "chatgpt", "tokens": {"access_token": "test-only"}}))
        task = task_for(case(), "the feline is here", self.rubric)
        expected = judgment(task)
        executable = self.root / "fake-codex"
        audit = self.root / "audit.json"
        executable.write_text(
            "#!/usr/bin/env python3\nimport os,sys,json\nfrom pathlib import Path\nif '--version' in sys.argv:\n print('test-codex 1'); sys.exit(0)\ntext=sys.stdin.read()\n"
            + f"Path({str(audit)!r}).write_text(json.dumps({{'api':bool(os.environ.get('OPENAI_API_KEY')), 'home':os.environ['CODEX_HOME'], 'arguments':sys.argv}}))\n"
            + "out=Path(sys.argv[sys.argv.index('--output-last-message')+1])\n"
            + f"out.write_text({json.dumps(expected)!r})\n"
            + "print(json.dumps({'type':'turn.completed','usage':{'input_tokens':10}}))\n"
        )
        executable.chmod(0o700)
        with patch.dict(os.environ, {"CODEX_HOME": str(home), "OPENAI_API_KEY": "test-only-api-key"}):
            result, metadata = codex(task, self.rubric, str(executable))
        recorded = read_json(audit)
        self.assertFalse(recorded["api"])
        self.assertNotEqual(recorded["home"], str(home))
        self.assertFalse(Path(recorded["home"]).exists())
        self.assertIn("skip_host_skill_discovery", recorded["arguments"])
        self.assertIn("suppress_unstable_features_warning=true", recorded["arguments"])
        self.assertEqual(metadata["auth"], "chatgpt")
        self.assertEqual(result, expected)


if __name__ == "__main__":
    unittest.main()
