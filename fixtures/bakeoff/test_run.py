"""The runner's interruption contract, without apps or screen access."""

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location("bakeoff_runner_under_test", HERE / "run.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class Idle:
    url = "unused"

    def __init__(self, *_):
        pass

    @staticmethod
    def build(_):
        pass

    def prepare(self):
        pass

    def start(self):
        pass

    def stop(self):
        pass


class InterruptedCase:
    def __init__(self, oops, server, host, case, nonce):
        self.case = case

    def run(self, first):
        if self.case["id"] == "interrupted":
            raise runner.e2e.ScreenUnavailable("a system dialog has focus")
        return {"id": self.case["id"], "expect": "works", "verdict": "pass", "stages": {}}


class RunTests(unittest.TestCase):
    def test_system_dialog_interrupts_a_wait_for_a_missing_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            oops = runner.Oops(Path(directory))
            with patch.object(runner.e2e, "require_screen", side_effect=runner.e2e.ScreenUnavailable("system dialog")):
                with self.assertRaises(runner.e2e.ScreenUnavailable):
                    oops.wait("attempt", 0, 30)

    def test_system_dialog_keeps_completed_cases_without_scoring_the_interrupted_one(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            work = Path(directory)
            cases = work / "cases"
            cases.mkdir()
            (cases / "cases.json").write_text(json.dumps([{"id": "completed"}, {"id": "interrupted"}]))
            out = work / "score.json"
            stack.enter_context(
                patch.object(sys, "argv", ["run.py", "--no-build", "--cases", str(cases), "--out", str(out)])
            )
            for name in ["Oops", "Server"]:
                stack.enter_context(patch.object(runner, name, Idle))
            stack.enter_context(patch.object(runner, "HOSTS", {"fixture": Idle}))
            stack.enter_context(patch.object(runner, "host_of", lambda _: "fixture"))
            stack.enter_context(patch.object(runner, "installed", lambda _: True))
            stack.enter_context(patch.object(runner, "CaseRun", InterruptedCase))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            with self.assertRaises(runner.e2e.ScreenUnavailable):
                runner.main()
            saved = json.loads(out.read_text())
            self.assertFalse(saved["complete"])
            self.assertEqual([case["id"] for case in saved["cases"]], ["completed"])
            self.assertEqual(saved["summary"]["passed"], 1)
            self.assertEqual(saved["summary"]["graded"], 1)


if __name__ == "__main__":
    unittest.main()
