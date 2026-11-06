import copy
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

from report import read_samples, summarize
from run import PilotError, collect, digest, verify_executable


def row(position):
    return {
        "pair": 1,
        "position": position,
        "outcome": "ok",
        "backendMs": 3.0,
        "task": {
            "identifier": position,
            "taskMs": 2.0,
            "redirectCount": 0,
            "transactions": [
                {
                    "reused": position == 2,
                    "proxy": False,
                    "fetch": "network",
                    "status": 200,
                    "networkProtocol": "http/1.1",
                },
            ],
        },
    }


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.server = {
            "requests": [{"pair": 1, "position": position, "connection": 1} for position in (1, 2)],
            "rejected": 0,
            "handlerErrors": 0,
        }

    def test_collection_refuses_the_shipping_checkout_before_build_or_write(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            out = scratch / "results"
            with (
                patch("run.ROOT", scratch / "shipping"),
                patch("run.shutil.which", return_value="/usr/bin/swift"),
                patch("run.require_local_dependencies", side_effect=AssertionError),
                self.assertRaises(PilotError) as error,
            ):
                collect(Namespace(out=out, dry_run=False))
            self.assertEqual(error.exception.code, "SWIFT_OVERLAY_REQUIRED")
            self.assertFalse(out.exists())

    def test_complete_pair_keeps_missing_phases_and_socket_evidence(self):
        report = summarize([row(1), row(2)], 0, self.server, 1)
        self.assertEqual(report["completePairs"], 1)
        self.assertEqual(report["sameSocketPairs"], 1)
        self.assertEqual(report["reuseDisagreements"], 0)
        self.assertEqual(report["first"]["tlsMs"], {"n": 0, "missing": 1, "p50": None, "p95": None})

    def test_invalid_phase_does_not_become_missing(self):
        for invalid in (True, -1, float("nan"), float("inf"), "1", None):
            with self.subTest(value=invalid):
                second = row(2)
                second["task"]["transactions"][0]["dnsMs"] = invalid
                report = summarize([row(1), second], 0, self.server, 1)
                self.assertEqual(report["invalidRows"], 1)
                self.assertEqual(report["completePairs"], 0)

    def test_duplicate_failed_and_missing_rows_never_form_complete_pairs(self):
        failure = {"pair": 1, "position": 2, "outcome": "requestFailed", "backendMs": 5.0}
        for rows in ([row(1), row(2), row(2)], [row(1), failure], [row(1)]):
            with self.subTest(rows=rows):
                report = summarize(rows, 0, self.server, 1)
                self.assertEqual(report["completePairs"], 0)
                self.assertEqual(report["sampleRows"], len(rows))

    def test_reuse_disagreement_is_retained(self):
        server = copy.deepcopy(self.server)
        server["requests"][1]["connection"] = 2
        report = summarize([row(1), row(2)], 0, server, 1)
        self.assertEqual(report["reuseDisagreements"], 1)
        self.assertEqual(report["sameSocketPairs"], 0)
        self.assertEqual(report["second"]["reportedReused"], 1)

    def test_https_checks_server_tls_version_and_keeps_missing_reuse_phase(self):
        server = copy.deepcopy(self.server)
        for request in server["requests"]:
            request.update(tlsVersion="TLSv1.3", tlsSessionResumed=True)
        first, second = row(1), row(2)
        transaction = first["task"]["transactions"][0]
        transaction.update(tlsProtocolCode=0x0304, tlsMs=1.5)
        report = summarize([first, second], 0, server, 1, scheme="https")
        self.assertEqual(report["completePairs"], 1)
        self.assertEqual(report["serverTLSVersions"], ["TLSv1.3"])
        self.assertEqual(report["resumedTLSSockets"], 1)
        self.assertEqual(report["first"]["tlsMs"]["p50"], 1.5)
        self.assertEqual(report["second"]["tlsMs"]["missing"], 1)
        transaction["tlsProtocolCode"] = 0x0303
        mismatched = summarize([first, second], 0, server, 1, scheme="https")
        self.assertEqual(mismatched["invalidRows"], 1)
        self.assertEqual(mismatched["completePairs"], 0)

    def test_partial_json_line_is_counted(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "samples.jsonl"
            path.write_bytes(b'{"pair":1}\n{"pair":')
            self.assertEqual(read_samples(path), ([{"pair": 1}], 1))

    def test_executable_replacement_fails_the_identity_check(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "test-executable"
            path.write_bytes(b"original test executable")
            expected = digest(path)
            self.assertEqual(verify_executable(path, expected), expected)
            path.write_bytes(b"replacement test executable")
            with self.assertRaises(PilotError) as error:
                verify_executable(path, expected)
            self.assertEqual(error.exception.code, "BINARY_CHANGED")
