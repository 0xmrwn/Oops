"""A preview build stays on this Mac: every step towards users refuses it. No tool, network or Keychain is used."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import release
from release_bundle import assemble, verify
from release_fakes import Builder, Inspector, preview_entitlements, stage
from release_notary import verify_distribution

ROOT = Path(__file__).resolve().parent.parent


class PreviewDistributionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.artifact = Path(directory.name) / "oops-1.2.3-42-preview"
        self.artifact.mkdir()
        self.app = self.artifact / "Oops.app"
        assemble(ROOT, self.app, stage(Path(directory.name)), "1.2.3", "42", Builder(), preview=True)
        self.inspector = Inspector(self.app, linked=True, entitlements=preview_entitlements())
        self.metadata = {
            "version": "1.2.3",
            "build_number": "42",
            "input_sha256": release.input_digest(),
            "signing_identity": None,
            "distributable": False,
            "preview": True,
            "verification": verify(ROOT, self.app, "1.2.3", "42", self.inspector, preview=True),
        }
        self.write(self.metadata)

    def write(self, metadata):
        (self.artifact / "build-info.json").write_text(json.dumps(metadata))

    def test_a_preview_artifact_verifies_locally(self):
        self.assertEqual(release.check_artifact(self.artifact, "verify", self.inspector), self.metadata)

    def test_every_distribution_step_refuses_a_preview_artifact(self):
        for command in ("notarize", "appcast", "dmg"):
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, "refuses a preview build"):
                release.check_artifact(self.artifact, command, self.inspector)

    def test_a_preview_artifact_claiming_otherwise_still_fails_on_its_contents(self):
        self.write(self.metadata | {"preview": False})
        for command in ("verify", "notarize", "appcast", "dmg"):
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, "microphone"):
                release.check_artifact(self.artifact, command, self.inspector)

    def test_distribution_verification_refuses_a_preview_app(self):
        (self.artifact / "Oops.zip").write_bytes(b"archive")
        metadata = self.metadata | {
            "preview": False,
            "distributable": True,
            "archive_sha256": hashlib.sha256(b"archive").hexdigest(),
        }
        inspector = self.inspector

        def run(command, **kwargs):
            if command[:2] == ["ditto", "-xk"]:
                shutil.copytree(self.app, Path(command[3]) / "Oops.app", symlinks=True)
                return ""
            return inspector(command, **kwargs)

        (ROOT / ".build").mkdir(exist_ok=True)
        with self.assertRaisesRegex(ValueError, "microphone"):
            verify_distribution(ROOT, self.artifact, metadata, run)

    def test_the_command_line_refuses_before_any_tool_runs(self):
        for command in (["notarize", "--keychain-profile", "p"], ["appcast"], ["dmg", "--keychain-profile", "p"]):
            with self.subTest(command=command[0]):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "script/release.py"),
                        *command,
                        "--artifact",
                        str(self.artifact),
                        "--dry-run",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("refuses a preview build", json.loads(result.stdout)["error"])


class PreviewBuildOptionTests(unittest.TestCase):
    def test_plan_shows_the_option_and_names_the_artifact_after_it(self):
        for flags, preview in (([], False), (["--preview"], True)):
            with self.subTest(preview=preview):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "script/release.py"),
                        "plan",
                        "--version",
                        "0.1.0",
                        "--build-number",
                        "1",
                    ]
                    + flags,
                    capture_output=True,
                    text=True,
                    check=True,
                )
                data = json.loads(result.stdout)["data"]
                self.assertIs(data["preview"], preview)
                self.assertEqual(data["artifact"].endswith("-preview"), preview)
                self.assertFalse(data["distributable"])

    def test_only_the_flag_sets_the_option_and_a_preview_compiles_apart(self):
        commands = []

        def run(command, *, capture=False):
            commands.append(command)
            return "/bin/path\n"

        for preview in (False, True):
            commands.clear()
            with (
                self.subTest(preview=preview),
                mock.patch.dict(os.environ, {"OOPS_PREVIEW": "1"}),
                mock.patch.object(release, "run", run),
            ):
                release.compile_release(1, preview)
                self.assertEqual(os.environ.get("OOPS_PREVIEW"), "1" if preview else None)
                scratch = Path(commands[0][commands[0].index("--scratch-path") + 1])
                self.assertEqual(scratch.name, "arm64-preview" if preview else "arm64")
                release.verify_debug_flags(Path("cache"), preview)
                self.assertEqual("OOPS_PREVIEW" in commands[-2], preview)


if __name__ == "__main__":
    unittest.main()
