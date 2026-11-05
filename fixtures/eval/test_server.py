"""Exercise the actual local HTTP boundary with invented data and no model calls."""

import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from evaluation.records import ROOT, lines, read_json
from evaluation.tasks import task_for
from test_pipeline import fixture, judgment


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.run = fixture(self.root, "the feline is here")
        self.process = subprocess.Popen(
            [sys.executable, str(ROOT / "manage.py"), "serve", "--runs", str(self.root), "--port", "0"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.url = self.process.stdout.readline().split()[2]

    def tearDown(self):
        self.process.terminate()
        self.process.communicate(timeout=5)
        self.temporary.cleanup()

    def get(self, path):
        with urllib.request.urlopen(self.url + path, timeout=5) as response:
            return json.load(response)

    def test_read_review_and_reload_persist_without_an_inference_endpoint(self):
        state = self.get("/api/state")
        case = self.get("/api/case?run=offline-test&id=c")
        task = case["answers"][0]["task"]
        payload = {"key": task["key"], "judgment": judgment(task)}
        request = urllib.request.Request(
            self.url + "/api/labels?run=offline-test",
            json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "X-Oops-Token": state["token"], "Origin": self.url},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            self.assertTrue(json.load(response)["saved"])
        self.assertEqual(self.get("/api/state")["lanes"][0]["metrics"]["correct"], 2)
        self.assertEqual(len(lines(self.run / "labels.jsonl")), 1)
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(self.url + "/api/judge", timeout=5)
        self.assertEqual(raised.exception.code, 404)

    def test_unauthorized_label_write_and_foreign_host_are_denied(self):
        payload = json.dumps({"key": "fake", "judgment": {}}).encode()
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(
                urllib.request.Request(self.url + "/api/labels?run=offline-test", payload), timeout=5
            )
        self.assertEqual(raised.exception.code, 403)
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(
                urllib.request.Request(self.url + "/api/state", headers={"Host": "foreign.invalid"}), timeout=5
            )
        self.assertEqual(raised.exception.code, 403)
        self.assertFalse((self.run / "labels.jsonl").exists())

    def test_malformed_review_is_an_error_and_does_not_change_the_results(self):
        state = self.get("/api/state")
        c = self.get("/api/case?run=offline-test&id=c")["case"]
        task = task_for(c, "the feline is here", read_json(ROOT / "rubric.json"))
        bad = judgment(task)
        bad["edits"] = [1]
        request = urllib.request.Request(
            self.url + "/api/labels?run=offline-test",
            json.dumps({"key": task["key"], "judgment": bad}).encode(),
            headers={"X-Oops-Token": state["token"], "Content-Type": "application/json"},
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request, timeout=5)
        self.assertEqual(raised.exception.code, 400)
        self.assertFalse((self.run / "labels.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
