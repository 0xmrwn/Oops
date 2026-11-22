"""Unit tests for wheel.py's checks, against a stand-in run: python3 -m unittest discover -s fixtures/e2e -p 'test_*.py'"""

import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import wheel


class Run:
    """Records triggers; an arrow tap lands its run's outcome at once, as a fast stub does."""

    def __init__(self, work):
        self.work, self.log, self.stub = work, work / "log", work / "stub.json"
        self.log.mkdir()
        self.triggers = []

    def write(self, path, value):
        path.write_text(json.dumps(value))

    def show(self, *args):
        pass

    def record(self, entry):
        with (self.log / "actions.jsonl").open("a") as file:
            file.write(json.dumps(entry) + "\n")

    def trigger(self, name, *arguments):
        self.triggers.append((name, *arguments))
        if name == "wheel-key" and arguments[0] != "escape":
            self.record({"wheel": "run", "invocation": "Shorten"})
            self.record(
                {"outcome": "written" if len([t for t in self.triggers if t[0] == "wheel-key"]) == 1 else "restored"}
            )
        if name == "wheel-state":
            self.record({"wheel": "state", "holder": ""})

    def wait(self, check, seconds, what):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if value := check():
                return value
        raise TimeoutError(what)

    def calls(self):
        return 0

    def state(self):
        return {"text": "draft"}

    def entries(self):
        return []


class OutcomeSteps(unittest.TestCase):
    def test_an_outcome_already_logged_is_not_waited_for_again(self):
        case = dict(
            name="wheel:restore",
            text="draft",
            steps=[("key", "down", "tap"), ("outcome",), ("key", "down", "tap"), ("outcome",)],
            outcomes=["written", "restored"],
        )
        with tempfile.TemporaryDirectory() as work, mock.patch.object(wheel.time, "sleep"):
            run = Run(Path(work))
            with mock.patch.object(wheel.inserts, "clipboard", return_value=b""):
                self.assertEqual(wheel.check(run, case), [])


if __name__ == "__main__":
    unittest.main()
