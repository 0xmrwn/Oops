"""Corruption and interruption checks for immutable evidence and append-only journals."""

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from evaluation.records import append, lines, load_run, read_json, write_json
from test_pipeline import fixture


class RecordsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.run = fixture(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def experiment(self, **changes):
        path = self.run / "experiment.json"
        value = {**read_json(path), **changes}
        write_json(path, value)
        return value

    def test_missing_snapshot_never_falls_back_to_original_corpus(self):
        original = self.root / "original.jsonl"
        original.write_bytes((self.run / "cases.jsonl").read_bytes())
        manifest = read_json(self.run / "manifest.json")
        write_json(self.run / "manifest.json", {**manifest, "cases": str(original)})
        (self.run / "cases.jsonl").unlink()
        with self.assertRaisesRegex(ValueError, "snapshot is missing or changed"):
            load_run(self.run)

    def test_changed_cases_config_and_prices_are_rejected(self):
        for name in ("cases.jsonl", "config.json", "prices.json"):
            with self.subTest(name=name):
                path = self.run / name
                if not path.exists():
                    write_json(path, {"models": {}})
                before = path.read_bytes()
                experiment = read_json(self.run / "experiment.json")
                self.experiment(snapshots={**experiment["snapshots"], name: hashlib.sha256(before).hexdigest()})
                path.write_bytes(before + b" ")
                with self.assertRaisesRegex(ValueError, "snapshot is missing or changed"):
                    load_run(self.run)
                path.write_bytes(before)
        self.assertEqual(len(load_run(self.run)[3]), 2)

    def test_unversioned_or_missing_snapshot_hashes_are_rejected(self):
        original = read_json(self.run / "experiment.json")
        for changes in ({"schema_version": 1}, {"snapshots": {}}, {"kind": "unknown"}):
            with self.subTest(changes=changes):
                write_json(self.run / "experiment.json", {**original, **changes})
                with self.assertRaises(ValueError):
                    load_run(self.run)

    def test_existing_prices_require_a_hash_and_calibration_provenance_is_verified(self):
        write_json(self.run / "prices.json", {})
        with self.assertRaisesRegex(ValueError, "snapshot hashes are missing"):
            load_run(self.run)
        (self.run / "prices.json").unlink()
        provenance = self.run / "provenance.json"
        write_json(provenance, {"kind": "invented negatives"})
        experiment = read_json(self.run / "experiment.json")
        self.experiment(
            kind="calibration",
            snapshots={
                **experiment["snapshots"],
                "provenance.json": hashlib.sha256(provenance.read_bytes()).hexdigest(),
            },
        )
        self.assertEqual(load_run(self.run)[0]["kind"], "calibration")
        write_json(provenance, {"kind": "changed"})
        with self.assertRaisesRegex(ValueError, "snapshot is missing or changed"):
            load_run(self.run)

    def test_snapshot_paths_and_symlinks_cannot_escape_run(self):
        outside = self.root / "outside.json"
        write_json(outside, {})
        experiment = read_json(self.run / "experiment.json")
        hash_value = hashlib.sha256(outside.read_bytes()).hexdigest()
        for name in ("../outside.json", str(outside), "outside.json"):
            with self.subTest(name=name):
                if name == "outside.json":
                    (self.run / name).symlink_to(outside)
                self.experiment(snapshots={**experiment["snapshots"], name: hash_value})
                with self.assertRaises(ValueError):
                    load_run(self.run)

    def test_records_require_valid_case_attempt_and_matching_lane(self):
        path = self.run / "results/api--a.jsonl"
        original = path.read_bytes()
        for changes in (
            {"case": "unknown"},
            {"attempt": 0},
            {"attempt": 3},
            {"attempt": True},
            {"provider": "other"},
            {"model": "other"},
            {"lane": "chatgpt"},
            {"run": "other-run"},
        ):
            with self.subTest(changes=changes):
                rows = [json.loads(line) for line in original.splitlines()]
                rows[0].update(changes)
                path.write_text("".join(json.dumps(row) + "\n" for row in rows))
                with self.assertRaises(ValueError):
                    load_run(self.run)
        path.write_bytes(original)
        self.assertEqual(len(load_run(self.run)[3]), 2)

    def test_manifest_cannot_reduce_the_frozen_attempt_count(self):
        manifest = read_json(self.run / "manifest.json")
        write_json(self.run / "manifest.json", {**manifest, "attempts": 1})
        with self.assertRaisesRegex(ValueError, "frozen experiment"):
            load_run(self.run)

    def test_legacy_runs_remain_readable_without_an_experiment(self):
        (self.run / "experiment.json").unlink()
        self.assertIsNone(load_run(self.run)[0])

    def test_append_recovers_only_interrupted_tail_and_preserves_valid_unterminated_json(self):
        journal = self.root / "judgments.jsonl"
        for tail in (b'{"key":', b'{"key":"caf\xc3', b'{"key":"valid"}'):
            with self.subTest(tail=tail):
                journal.write_bytes(b'{"key":"first"}\n' + tail)
                before = lines(journal)
                append(journal, {"key": "next"})
                self.assertEqual(lines(journal), [*before, {"key": "next"}])
                self.assertTrue(journal.read_bytes().endswith(b"\n"))

    def test_completed_malformed_rows_are_fatal_and_never_rewritten(self):
        journal = self.root / "judgments.jsonl"
        for bad in (b'{"key":\n', b'{"key":"caf\xc3\n'):
            with self.subTest(bad=bad):
                original = b'{"key":"first"}\n' + bad
                journal.write_bytes(original)
                with self.assertRaisesRegex(ValueError, "Invalid JSONL"):
                    lines(journal)
                with self.assertRaisesRegex(ValueError, "Invalid JSONL"):
                    append(journal, {"key": "next"})
                self.assertEqual(journal.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
