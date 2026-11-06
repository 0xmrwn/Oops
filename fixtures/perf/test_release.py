"""Offline contracts. All PID/profiler/artifact-verifier calls are mocked; no Oops is run."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import evidence
import release


class ReleasePerformanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.context = self.root / "context.json"
        context = json.loads((Path(__file__).parent / "context.example.json").read_text())
        context.update(display_mode="synthetic offline test display", power="synthetic test power")
        self.context.write_text(json.dumps(context))
        self.args = release.parser().parse_args(
            [
                "record",
                "--artifact",
                str(self.root / "artifact"),
                "--context",
                str(self.context),
                "--pid",
                "12345",
                "--out",
                str(self.root / "run"),
                "--mode",
                "time-profile",
                "--seconds",
                "1",
            ]
        )

    def sample(self, value, **fields):
        return {
            "metric": "capture_ms",
            "value": value,
            "case": "synthetic",
            "condition": "warm-process",
            "outcome": "fixed",
            "source": "reviewed-trace",
            **fields,
        }

    def write_samples(self, samples):
        path = self.root / "samples.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in samples))
        return path

    def test_plan_and_dry_run_never_verify_attach_or_write(self):
        with (
            patch.object(release, "verify_artifact", side_effect=AssertionError),
            patch.object(release, "identity", side_effect=AssertionError),
            patch.object(release.subprocess, "run", side_effect=AssertionError),
        ):
            plan = release.plan(self.args)
            self.args.dry_run = True
            self.assertEqual(release.collect(self.args), plan)
        self.assertFalse(self.args.out.exists())
        command = plan["commands"][0]
        self.assertIn("--attach", command)
        self.assertIn("12345", command)
        self.assertNotIn("--launch", command)
        self.assertNotIn("--all-processes", command)

    def test_missing_session_refuses_before_native_access(self):
        with patch.object(release, "verify_artifact", side_effect=AssertionError):
            with self.assertRaisesRegex(ValueError, "session-ready"):
                release.collect(self.args)
        self.assertFalse(self.args.out.exists())

    def test_existing_output_is_never_overwritten(self):
        self.args.session_ready = True
        self.args.out.mkdir()
        marker = self.args.out / "keep"
        marker.write_text("original")
        with patch.object(release, "verify_artifact", side_effect=AssertionError):
            with self.assertRaisesRegex(ValueError, "output exists"):
                release.collect(self.args)
        self.assertEqual(marker.read_text(), "original")

    def test_example_context_is_plan_only(self):
        self.args.session_ready = True
        self.context.write_text((Path(__file__).parent / "context.example.json").read_text())
        with patch.object(release, "verify_artifact", side_effect=AssertionError):
            self.assertEqual(release.plan(self.args)["status"], "planned-not-verified")
            with self.assertRaisesRegex(ValueError, "replace example"):
                release.collect(self.args)

    def test_debug_and_dirty_builds_refused_before_packaging_verification(self):
        with patch.object(release, "command", side_effect=AssertionError):
            for metadata in (
                {"configuration": "debug", "source_dirty": False},
                {"configuration": "release", "source_dirty": True},
                {"configuration": "release"},
            ):
                with patch.object(release, "read_json", return_value=metadata):
                    with self.assertRaisesRegex(ValueError, "clean-source Release"):
                        release.verify_artifact(self.root)

    def test_artifact_gate_is_verify_only(self):
        metadata = {"configuration": "release", "source_dirty": False}
        owning_checkout = self.root / "owning-checkout"
        with patch.object(release, "read_json", return_value=metadata), patch.object(release, "command") as run:
            self.assertEqual(release.verify_artifact(self.root, owning_checkout), metadata)
        self.assertEqual(run.call_args.args[0][1], str(owning_checkout / "script/release.py"))
        self.assertEqual(run.call_args.args[0][2:], ["verify", "--artifact", str(self.root)])

    def test_wrong_pid_path_refused(self):
        with patch.object(release.sys, "platform", "darwin"), patch.object(release.ctypes, "CDLL") as library:

            def pidpath(_pid, buffer, _length):
                buffer.value = b"/tmp/other.app/Contents/MacOS/oops"
                return len(buffer.value)

            library.return_value.proc_pidpath.side_effect = pidpath
            with self.assertRaisesRegex(ValueError, "does not match"):
                release.identity(12345, self.root / "Oops.app/Contents/MacOS/oops")

    def test_failed_capture_preserves_incomplete_manifest(self):
        self.args.session_ready = True
        artifact = self.args.artifact
        artifact.mkdir()
        (artifact / "build-info.json").write_text("{}")
        metadata = {"configuration": "release", "source_dirty": False}

        def fake_command(args, **_kwargs):
            return "16000000000" if "hw.memsize" in args else "test"

        with (
            patch.object(release, "verify_artifact", return_value=metadata),
            patch.object(release, "identity", return_value={"pid": 12345}),
            patch.object(release, "command", side_effect=fake_command),
            patch.object(release.shutil, "disk_usage") as disk,
            patch.object(release.subprocess, "run", side_effect=RuntimeError("fake capture failed")),
        ):
            disk.return_value.free = 100 * 1024**3
            with self.assertRaisesRegex(RuntimeError, "fake capture failed"):
                release.collect(self.args)
        self.assertEqual(json.loads((self.args.out / "manifest.json").read_text())["status"], "incomplete")
        self.assertFalse((self.args.out / "result.json").exists())

    def test_success_rechecks_identity_and_artifact(self):
        self.args.session_ready = True
        self.args.artifact.mkdir()
        (self.args.artifact / "build-info.json").write_text("{}")
        with (
            patch.object(release, "verify_artifact", return_value={}) as verifier,
            patch.object(release, "identity", return_value={"pid": 12345}) as identify,
            patch.object(release, "command", return_value="16"),
            patch.object(release.shutil, "disk_usage") as disk,
            patch.object(release.subprocess, "run") as profiler,
        ):
            disk.return_value.free = 100 * 1024**3

            def fake_trace(*_args, **_kwargs):
                trace = self.args.out / "capture.trace"
                trace.mkdir()
                (trace / "data").write_text("synthetic profiler output")

            profiler.side_effect = fake_trace
            self.assertEqual(release.collect(self.args)["status"], "collected")
        self.assertEqual(verifier.call_count, 2)
        self.assertEqual(identify.call_count, 2)
        self.assertEqual(profiler.call_count, 1)
        self.assertEqual(json.loads((self.args.out / "result.json").read_text())["status"], "collected")

    def test_stack_mode_stays_bounded_without_relaxing_the_instruments_floor(self):
        self.args.session_ready = True
        self.args.artifact.mkdir()
        (self.args.artifact / "build-info.json").write_text("{}")

        def fake_sample(argv, **kwargs):
            self.assertEqual(argv, ["/usr/bin/sample", "12345", "1", "10", "-file", str(self.args.out / "stacks.txt")])
            self.assertEqual(kwargs["preexec_fn"], release.limit_stack_file_size)
            self.assertEqual(kwargs["timeout"], 11)
            (self.args.out / "stacks.txt").write_text("Call graph:\n    1 synthetic frame\n")

        with (
            patch.object(release, "verify_artifact", return_value={}),
            patch.object(release, "identity", return_value={"pid": 12345}),
            patch.object(release, "command", return_value="16"),
            patch.object(release.shutil, "disk_usage") as disk,
            patch.object(release.subprocess, "run", side_effect=fake_sample) as profiler,
        ):
            disk.return_value.free = 128 * 1024**2
            with self.assertRaisesRegex(ValueError, "30 GiB"):
                release.collect(self.args)
            profiler.assert_not_called()
            self.args.mode = "sample-stacks"
            self.args.seconds = 11
            with self.assertRaisesRegex(ValueError, "1–10 seconds"):
                release.collect(self.args)
            self.args.seconds = 1
            self.assertEqual(release.collect(self.args)["status"], "collected")

    def test_missing_samples_stay_missing_and_cohorts_stay_separate(self):
        path = self.write_samples(
            [
                self.sample(None),
                self.sample(10, condition="cold-process"),
                self.sample(20, condition="cold-process"),
                self.sample(None, outcome="failed"),
            ]
        )
        summary = evidence.summarize(path)
        measured = next(row for row in summary["groups"] if row["n"])
        self.assertEqual((measured["n"], measured["p50"], measured["p95"]), (2, 10, 20))
        pending = [row for row in summary["groups"] if row["status"] == "pending"]
        self.assertEqual(len(pending), 2)
        self.assertTrue(all("p95" not in row for row in pending))
        self.assertEqual(summary["acceptance"], "not-assessed")
        self.assertIn("launch_ms", summary["pending_metrics"])

    def test_invalid_scalar_or_unknown_schema_refused(self):
        for value in (True, -1, float("nan"), float("inf"), "1"):
            with self.assertRaises(ValueError):
                evidence.validate_sample(self.sample(value))
        with self.assertRaises(ValueError):
            evidence.validate_sample(self.sample(1, draft="private"))
        context = json.loads(self.context.read_text())
        context["display_hz"] = None
        with self.assertRaisesRegex(ValueError, "observed"):
            evidence.validate_context(context)

    def test_diagnostic_extraction_whitelists_and_preserves_failure_and_missing(self):
        log = self.root / "private.jsonl"
        log.write_text(
            json.dumps(
                {
                    "v": 1,
                    "kind": "attempt",
                    "id": "selected",
                    "outcome": "failed",
                    "draft": "SECRET DRAFT",
                    "error": "SECRET ERROR",
                    "timings": {"capture": 12},
                }
            )
            + "\n"
            + json.dumps({"kind": "attempt", "id": "unselected", "draft": "SECRET"})
            + "\n"
        )
        selection = self.root / "selection.json"
        selection.write_text(json.dumps({"selected": {"case": "synthetic", "condition": "warm-process"}}))
        result = evidence.timings(log, selection)
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertEqual(result["attempts"], 1)
        self.assertEqual([row["value"] for row in result["samples"]], [12, None])
        self.assertTrue(all(row["outcome"] == "failed" for row in result["samples"]))
        selection.write_text(json.dumps({"missing": {"case": "synthetic", "condition": "warm-process"}}))
        with self.assertRaisesRegex(ValueError, "missing"):
            evidence.timings(log, selection)

    def test_cli_json_failure_and_schema(self):
        for argv, expected in ((["schema"], 0), (["summarize", "--samples", str(self.root / "missing")], 1)):
            stream = io.StringIO()
            with contextlib.redirect_stdout(stream):
                self.assertEqual(release.main(argv), expected)
            self.assertEqual(json.loads(stream.getvalue())["ok"], expected == 0)

    def test_layered_help_never_touches_native_tools(self):
        commands = ("schema", "verify", "plan", "record", "summarize", "timings")
        with patch.object(release.subprocess, "run", side_effect=AssertionError):
            for argv in (
                ["--help"],
                ["help"],
                *([name, "--help"] for name in commands),
                *(["help", name] for name in commands),
            ):
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exited:
                    release.main(argv)
                self.assertEqual(exited.exception.code, 0)


if __name__ == "__main__":
    unittest.main()
