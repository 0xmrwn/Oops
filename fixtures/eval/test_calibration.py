"""Offline calibration preparation freezes provenance, never calls a provider."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from evaluation.calibration import prepare_calibration, public_stress, sha
from evaluation.records import canonical, load_run, read_json, write_json


def source_run(root, cases=None):
    directory = root / "source"
    directory.mkdir()
    cases = cases or [
        {"id": "c", "input": "teh cat", "expected": "the cat", "origin": "synthetic", "lang": "en", "split": "dev"}
    ]
    corpus = directory / "cases.jsonl"
    corpus.write_text("".join(canonical(case) + "\n" for case in cases))
    file = "results/api--model.jsonl"
    (directory / "results").mkdir()
    (directory / file).write_text(
        "".join(
            canonical(
                {
                    "case": case["id"],
                    "attempt": 1,
                    "output": case.get("expected", "a candidate"),
                    "raw": canonical({"text": case.get("expected", "a candidate")}),
                    "verdict": "changed",
                    "lane": "api",
                    "provider": "test",
                    "model": "model",
                }
            )
            + "\n"
            for case in cases
        )
    )
    write_json(
        directory / "manifest.json",
        {
            "run": "source",
            "cases": str(corpus),
            "attempts": 1,
            "prompt": "historical-version",
            "lanes": [
                {
                    "file": file,
                    "lane": "api",
                    "provider": "test",
                    "model": "model",
                    "resolved": "model",
                    "state": "done",
                }
            ],
        },
    )
    return directory


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_preparation_is_offline_idempotent_and_preserves_original_evidence(self):
        source = source_run(self.root)
        before = {str(path.relative_to(source)): path.read_bytes() for path in source.rglob("*") if path.is_file()}
        with (
            patch("evaluation.judges.codex", side_effect=AssertionError("inference")),
            patch("evaluation.judges.decisions", side_effect=AssertionError("inference")),
        ):
            result = prepare_calibration(source, self.root, "calibration", 30)
        self.assertFalse(result["generation_started"])
        self.assertGreater(result["authored_records"], 0)
        self.assertLessEqual(result["selected_records"], 30)
        directory = self.root / "calibration"
        experiment, manifest, cases, records = load_run(directory)
        self.assertEqual(experiment["kind"], "calibration")
        self.assertEqual(manifest["prompt"], "historical-version")
        self.assertEqual(experiment["snapshots"]["cases.jsonl"], sha(directory / "cases.jsonl"))
        self.assertEqual(next(r for r in records if r["case"] == "c")["output"], "the cat")
        self.assertIn("mixed", result["coverage"]["lang"])
        self.assertIn("fr", result["coverage"]["lang"])
        self.assertTrue(all(c["split"] == "dev" for c in cases.values()))
        self.assertEqual(read_json(directory / "provenance.json")["source_prompt_version"], "historical-version")
        self.assertTrue(prepare_calibration(source, self.root, "calibration", 30)["unchanged"])
        self.assertEqual(
            before, {str(path.relative_to(source)): path.read_bytes() for path in source.rglob("*") if path.is_file()}
        )

    def test_unknown_private_and_held_cases_do_not_enter_a_cloud_panel(self):
        source = source_run(self.root, [{"id": "private", "input": "private", "expected": "Private"}])
        with self.assertRaisesRegex(ValueError, "marked synthetic"):
            prepare_calibration(source, self.root, "calibration", 1)
        self.assertFalse((self.root / "calibration").exists())
        case_file = source / "cases.jsonl"
        original = json.loads(case_file.read_text())
        for changes in [{"origin": "real"}, {"origin": "synthetic", "split": "held"}]:
            case_file.write_text(canonical({**original, **changes}) + "\n")
            with self.assertRaisesRegex(ValueError, "No eligible"):
                prepare_calibration(source, self.root, "calibration", 1)

    def test_unmarked_public_stress_evidence_is_verified_not_inferred_from_its_id(self):
        public, _ = public_stress()
        source = source_run(self.root, [public["stress-04"]])
        result = prepare_calibration(source, self.root, "calibration", 1)
        self.assertEqual(result["coverage"]["lang"], {"fr": 1})
        self.assertEqual(result["missing_references"], 1)
        case_file = source / "cases.jsonl"
        case_file.write_text(canonical({**public["stress-04"], "input": "different private draft"}) + "\n")
        with self.assertRaisesRegex(ValueError, "marked synthetic"):
            prepare_calibration(source, self.root, "other", 1)

    def test_existing_panels_and_invalid_destinations_are_refused(self):
        source = source_run(self.root)
        prepare_calibration(source, self.root, "calibration", 1)
        for name in ("../escape", "source"):
            with self.assertRaises(ValueError):
                prepare_calibration(source, self.root, name, 1)
        with self.assertRaisesRegex(ValueError, "different panel"):
            prepare_calibration(source, self.root, "calibration", 2)
        with self.assertRaisesRegex(ValueError, "not another calibration"):
            prepare_calibration(self.root / "calibration", self.root, "copy", 1)


if __name__ == "__main__":
    unittest.main()
