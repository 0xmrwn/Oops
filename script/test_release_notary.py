"""Submission recovery tests with synthetic files and no calls to Apple's service."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from release_bundle import hashes
from release_notary import notarize

SUBMISSION = "11111111-1111-4111-8111-111111111111"


class NotaryTests(unittest.TestCase):
    def fixture(self, root):
        artifact = root / "dist/release/oops-0.1.0-3"
        app = artifact / "Oops.app"
        app.mkdir(parents=True)
        (app / "payload").write_text("immutable signed payload")
        metadata = {
            "version": "0.1.0",
            "build_number": "3",
            "signing_identity": "A" * 40,
            "verification": {"files": hashes(app)},
        }
        (artifact / "build-info.json").write_text(json.dumps(metadata))
        return artifact, metadata

    def test_adhoc_is_refused_before_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact, metadata = self.fixture(root)
            metadata["signing_identity"] = None
            with self.assertRaisesRegex(ValueError, "ad-hoc signing is refused"):
                notarize(root, artifact, metadata, "oops-notary", 0, False, self.unexpected)

    def unexpected(self, *args, **kwargs):
        self.fail("No external command expected")

    def test_dry_run_never_creates_a_job_or_uploads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact, metadata = self.fixture(root)
            result = notarize(root, artifact, metadata, "oops-notary", 0, True, self.unexpected)
            self.assertEqual(result["upload_to"], "Apple notary service")
            self.assertFalse((root / ".build").exists())

    def test_pending_and_rejected_submissions_resume_without_duplicate_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact, metadata = self.fixture(root)

            def commands(command):
                self.assertEqual(command[0], "ditto")
                if "-c" in command:
                    Path(command[-1]).write_bytes(b"test submission archive")
                else:
                    shutil.copytree(command[1], command[2])

            submitted = []
            status = ["In Progress"]

            def service(command, profile):
                if command[0] == "submit":
                    submitted.append(command)
                    return {"id": SUBMISSION}
                self.assertEqual(command, ["info", SUBMISSION])
                return {"id": SUBMISSION, "status": status[0]}

            def rejection_log(command):
                self.assertEqual(command[:3], ["xcrun", "notarytool", "log"])
                Path(command[4]).write_text(json.dumps({"status": "Invalid", "issues": []}))

            with patch("release_notary.notary_json", side_effect=service):
                first = notarize(root, artifact, metadata, "oops-notary", 0, False, commands)
                second = notarize(root, artifact, metadata, "oops-notary", 0, False, self.unexpected)
                status[0] = "Invalid"
                for _ in range(2):
                    with self.assertRaisesRegex(ValueError, "Apple returned Invalid"):
                        notarize(root, artifact, metadata, "oops-notary", 0, False, rejection_log)
            self.assertEqual(first["submission_id"], second["submission_id"])
            self.assertEqual(len(submitted), 1)
            self.assertEqual(hashes(artifact / "Oops.app"), metadata["verification"]["files"])
            self.assertTrue((root / ".build/notarization/oops-0.1.0-3/notary-log.json").is_file())


if __name__ == "__main__":
    unittest.main()
