"""Exercise the locked protocol with the versioned public fixtures and simulated lane outputs."""

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from evaluation.comparison import LEGACY_VERSION, ROLES, VERSION, comparison, paired
from evaluation.judge_guards import context
from evaluation.records import ROOT, canonical, digest, lines, read_json, write_json
from evaluation.shortcut import measure
from evaluation.tasks import task_for


class BlindComparisonTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.run = Path(temp.name)
        (self.run / "results").mkdir()
        self.rubric = read_json(ROOT / "rubric.json")
        corpus = lines(ROOT / "cases.jsonl")
        self.cases = [
            next(
                c for c in corpus if c["lang"] == lang and c["expected"] != c["input"] and len(c["input"].split()) < 30
            )
            for lang in ("en", "fr", "mixed")
        ]
        self.cases.append(next(c for c in corpus if c["expected"] == c["input"] and len(c["input"].split()) < 30))
        twin = dict(self.cases[2], id="fixture-twin", family=self.cases[2]["id"], instructions="Use formal wording")
        self.cases[2]["instructions"] = "Keep the casual tone"
        self.cases.append(twin)
        self.write_lines(self.run / "cases.jsonl", self.cases)
        roles = {r: f"results/{r}.jsonl" for r in ROLES}
        write_json(
            self.run / "config.json",
            {
                "comparison": {
                    "protocol": VERSION,
                    "purpose": "fixture",
                    "lanes": roles,
                    "rubric_sha256": digest(self.rubric),
                }
            },
        )
        self.exp = {
            "schema_version": 2,
            "attempts": 1,
            "snapshots": {
                name: hashlib.sha256((self.run / name).read_bytes()).hexdigest()
                for name in ("cases.jsonl", "config.json")
            },
        }
        write_json(self.run / "experiment.json", self.exp)
        write_json(self.run / "manifest.json", {"attempts": 1, "lanes": [{"file": file} for file in roles.values()]})
        labels = []
        for c in self.cases:
            t = task_for(c, c["expected"], self.rubric)
            j = {
                "fully_correct": "yes",
                "faithful": "yes",
                "explanation": "fixture",
                "edits": [
                    {"id": e["id"], "verdict": "needed", "explanation": "fixture"} for e in t["evidence"]["edits"]
                ],
                "misses": [
                    {"id": e["id"], "verdict": "satisfied", "explanation": "fixture"}
                    for e in t["evidence"]["reference_edits"]
                ],
            }
            labels.append({"judge": "human", "status": "ok", "key": t["key"], "judgment": j, "blind_send_as_is": True})
        self.write_lines(self.run / "labels.jsonl", labels)
        for role, file in roles.items():
            rows = [
                {
                    "attempt": 1,
                    "case": c["id"],
                    "output": c["expected"],
                    "raw": canonical({"text": c["expected"]}),
                    "checks": {"protected_kept": True, "applied_protected_kept": True},
                }
                for c in self.cases
            ]
            if role == "liquid-tuned":
                rows[0].update(output=None, raw=None, error="timeout")
                rows[-1]["checks"]["protected_kept"] = False
            self.write_lines(self.run / file, rows)

    @staticmethod
    def write_lines(path, rows):
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))

    def refreeze(self, *files):
        for name in files:
            self.exp["snapshots"][name] = hashlib.sha256((self.run / name).read_bytes()).hexdigest()
        write_json(self.run / "experiment.json", self.exp)

    def test_fixture_matrix_and_shortcut(self):
        with patch("evaluation.shortcut.time.monotonic_ns", return_value=901_000_000):
            obs = measure(lambda: 1_000_000, lambda: True, "warm", lambda: 100, 200)
        self.write_lines(
            self.run / "shortcut.jsonl",
            [dict(obs, role="liquid-tuned", case=self.cases[1]["id"], experiment=digest(self.exp))],
        )
        result = comparison(self.run, self.rubric)
        model = result["models"]["liquid-tuned"]
        self.assertEqual(model["counts"]["failed"], 1)
        self.assertEqual(model["counts"]["send_yes"], 4)
        self.assertEqual(model["counts"]["raw_protection_failed"], 1)
        self.assertEqual(model["timing"]["warm_p95_ms"], 900)
        self.assertEqual(model["preference_groups"], 1)
        self.assertEqual(result["paired_send_as_is"]["liquid-tuned"]["luna"]["families"], 4)
        self.assertEqual(result["paired_send_as_is"]["qwen-tuned"]["haiku"]["decision"], "inconclusive")

    def test_qualification_rejects_fixture_corpus_and_snapshot_drift(self):
        config = read_json(self.run / "config.json")
        config["comparison"]["purpose"] = "qualification"
        write_json(self.run / "config.json", config)
        with self.assertRaisesRegex(ValueError, "snapshot"):
            comparison(self.run, self.rubric)
        self.exp["snapshots"]["config.json"] = hashlib.sha256((self.run / "config.json").read_bytes()).hexdigest()
        write_json(self.run / "experiment.json", self.exp)
        with self.assertRaisesRegex(ValueError, "held-out real"):
            comparison(self.run, self.rubric)
        only_english = dict(self.cases[0], origin="real", family="f", lang="en", split="held")
        for file in (self.run / "results").glob("*.jsonl"):
            self.write_lines(file, lines(file)[:1])
        self.write_lines(self.run / "cases.jsonl", [only_english])
        self.exp["snapshots"]["cases.jsonl"] = hashlib.sha256((self.run / "cases.jsonl").read_bytes()).hexdigest()
        write_json(self.run / "experiment.json", self.exp)
        with self.assertRaisesRegex(ValueError, "English and French"):
            comparison(self.run, self.rubric)

    def test_qualification_accepts_two_primary_languages_without_term_annotations(self):
        cases = [dict(c, origin="real", family=c["id"], split="held") for c in self.cases[:2]]
        self.write_lines(self.run / "cases.jsonl", cases)
        config = read_json(self.run / "config.json")
        plan = config["comparison"]
        plan.update(
            purpose="qualification",
            models={role: role for role in ROLES},
            shortcut_cases={cases[0]["id"]: "cold", cases[1]["id"]: "warm"},
        )
        write_json(self.run / "config.json", config)
        write_json(
            self.run / "manifest.json",
            {"attempts": 1, "lanes": [{"file": file, "resolved": role} for role, file in plan["lanes"].items()]},
        )
        for file in (self.run / "results").glob("*.jsonl"):
            self.write_lines(file, lines(file)[:2])
        self.refreeze("cases.jsonl", "config.json")
        result = comparison(self.run, self.rubric)
        model = result["models"]["qwen-tuned"]
        self.assertFalse(result["fixture_only"])
        self.assertEqual(model["english_term_preservation"]["occurrences"], 0)
        self.assertEqual(set(model["by_slice"]) & {"lang/en", "lang/fr", "lang/mixed"}, {"lang/en", "lang/fr"})

        plan["protocol"] = LEGACY_VERSION
        write_json(self.run / "config.json", config)
        self.refreeze("config.json")
        with self.assertRaisesRegex(ValueError, "English, French and mixed"):
            comparison(self.run, self.rubric)

    def test_english_term_report_distinguishes_raw_applied_and_unavailable(self):
        case = self.cases[1]
        case.update(
            input="Vérifie l’endpoint et le endpoint de test.",
            expected="Vérifie l’endpoint et l’endpoint de test.",
            tags={"english_terms": ["endpoint"]},
        )
        self.write_lines(self.run / "cases.jsonl", self.cases)
        self.refreeze("cases.jsonl")
        for role, raw, output in (
            ("qwen-tuned", canonical({"text": "Vérifie l’endpoint et les endpoints."}), case["expected"]),
            ("liquid-tuned", canonical({"text": case["input"]}), None),
            ("proofread", None, "Vérifie les points de terminaison."),
        ):
            file = self.run / f"results/{role}.jsonl"
            rows = lines(file)
            rows[1].update(raw=raw, output=output)
            self.write_lines(file, rows)
        file = self.run / "results/luna.jsonl"
        self.write_lines(file, [row for row in lines(file) if row["case"] != case["id"]])
        models = comparison(self.run, self.rubric)["models"]
        qwen = models["qwen-tuned"]["english_term_preservation"]
        self.assertEqual(qwen["drafts"], 1)
        self.assertEqual(qwen["occurrences"], 2)
        self.assertEqual(qwen["raw"], {"preserved": 1, "changed": 1, "unavailable": 0})
        self.assertEqual(qwen["applied"], {"preserved": 2, "changed": 0, "unavailable": 0})
        self.assertEqual(models["liquid-tuned"]["english_term_preservation"]["raw"]["preserved"], 2)
        self.assertEqual(models["liquid-tuned"]["english_term_preservation"]["applied"]["unavailable"], 2)
        self.assertEqual(models["proofread"]["english_term_preservation"]["raw"]["unavailable"], 2)
        self.assertEqual(models["proofread"]["english_term_preservation"]["applied"]["changed"], 2)
        self.assertEqual(models["luna"]["english_term_preservation"]["applied"]["unavailable"], 2)

        case["alternatives"] = ["Vérifie l’endpoint et le point de terminaison de test."]
        self.write_lines(self.run / "cases.jsonl", self.cases)
        self.refreeze("cases.jsonl")
        with self.assertRaisesRegex(ValueError, "survive in its references"):
            comparison(self.run, self.rubric)

    def test_non_boolean_protection_result_cannot_pass(self):
        path = self.run / "results/qwen-tuned.jsonl"
        rows = lines(path)
        rows[0]["checks"]["applied_protected_kept"] = "false"
        self.write_lines(path, rows)
        model = comparison(self.run, self.rubric)["models"]["qwen-tuned"]
        self.assertEqual(model["gates"]["protected_spans"], "inconclusive")

    def test_missing_votes_cannot_qualify(self):
        rows = lines(self.run / "labels.jsonl")
        rows[0]["judge"] = "agent"
        rows[1].pop("blind_send_as_is")
        self.write_lines(self.run / "labels.jsonl", rows)
        r = comparison(self.run, self.rubric)
        self.assertEqual(r["models"]["qwen-tuned"]["counts"]["awaiting_blind_vote"], 2)
        self.assertEqual(r["paired_send_as_is"]["qwen-tuned"]["luna"]["decision"], "inconclusive")

    def test_preference_reaches_judge_and_changes_identity(self):
        c = self.cases[2]
        a = task_for(c, c["input"], self.rubric)
        b = task_for(dict(c, instructions="Use formal wording"), c["input"], self.rubric)
        self.assertNotEqual(a["reference_key"], b["reference_key"])
        self.assertEqual(context(a, self.rubric)["active_editing_instructions"], "Keep the casual tone")

    def test_decisions_at_scale(self):
        for difference, expected in [(0, "pass"), (-1, "fail")]:
            self.assertEqual(paired({i: [difference] for i in range(2000)}, 0.03)["decision"], expected)

    def test_imported_editor_lane_is_replayable_and_blind(self):
        from evaluation.comparison_import import import_lane
        from evaluation.scoring import case_detail
        from evaluation.server import blind_case

        role = "proofread"
        file = f"results/{role}.jsonl"
        manifest = read_json(self.run / "manifest.json")
        manifest["lanes"] = [lane for lane in manifest["lanes"] if lane["file"] != file]
        write_json(self.run / "manifest.json", manifest)
        (self.run / file).unlink()
        path = self.run / "observations.jsonl"
        rows = [
            {
                "role": role,
                "experiment": digest(self.exp),
                "model": "hidden-source",
                "case": c["id"],
                "output": c["expected"],
                "error": None,
                "raw": canonical({"text": c["expected"]}),
            }
            for c in self.cases
        ]
        config = read_json(self.run / "config.json")
        config["comparison"].update(purpose="qualification", models={role: "hidden-source"})
        write_json(self.run / "config.json", config)
        self.exp["snapshots"]["config.json"] = hashlib.sha256((self.run / "config.json").read_bytes()).hexdigest()
        write_json(self.run / "experiment.json", self.exp)
        for r in rows:
            r.update(model="wrong-build", experiment=digest(self.exp))
        self.write_lines(path, rows)
        with self.assertRaisesRegex(ValueError, "registered build"):
            import_lane(self.run, role, path)
        self.assertFalse((self.run / file).exists())
        config["comparison"]["purpose"] = "fixture"
        write_json(self.run / "config.json", config)
        self.exp["snapshots"]["config.json"] = hashlib.sha256((self.run / "config.json").read_bytes()).hexdigest()
        write_json(self.run / "experiment.json", self.exp)
        for r in rows:
            r.update(model="hidden-source", experiment=digest(self.exp))
        self.write_lines(path, rows)
        self.assertEqual(import_lane(self.run, role, path), import_lane(self.run, role, path))
        detail = blind_case(case_detail(self.run, self.cases[0]["id"], self.rubric))
        self.assertNotIn("hidden-source", canonical(detail))
        self.assertNotIn("shortcut_ns", canonical(detail))
        self.assertEqual(len(detail["answers"]), 1)
        self.assertEqual(comparison(self.run, self.rubric)["models"][role]["counts"]["send_yes"], 5)
        rows[0]["output"] = "other"
        self.write_lines(path, rows)
        with self.assertRaisesRegex(ValueError, "differ"):
            import_lane(self.run, role, path)
