"""Every bundle carries dictation's parts: the speech engine, the microphone and Automation texts, and the licences."""

import os
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path

from release_bundle import AUTOMATION_USAGE, MICROPHONE_USAGE, assemble, resources, verify
from release_fakes import Builder, Inspector, stage
from release_signing import AUDIO_INPUT, ENGINE, LIBRARY_VALIDATION

ROOT = Path(__file__).resolve().parent.parent


class EngineBundleTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.stage = Path(directory.name)
        self.app = self.stage / "Oops.app"

    def build(self, engine=True):
        builder = Builder()
        assemble(ROOT, self.app, stage(self.stage, engine), "1.2.3", "42", builder)
        return builder

    def info(self):
        return plistlib.loads((self.app / "Contents/Info.plist").read_bytes())

    def verify(self, **faults):
        return verify(ROOT, self.app, "1.2.3", "42", Inspector(self.app, **faults))

    def test_a_bundle_embeds_the_engine_trimmed_and_thinned_and_asks_for_the_microphone(self):
        builder = self.build()
        engine = self.app / ENGINE
        self.assertTrue((engine / "Versions/A/CTranscribe").is_file())
        for name in ("Headers", "Modules"):
            self.assertFalse(os.path.lexists(engine / name), name)
            self.assertFalse(os.path.lexists(engine / "Versions/A" / name), name)
        self.assertEqual(sorted(builder.thinned), ["Autoupdate", "CTranscribe", "Sparkle"])
        self.assertEqual(self.info()["NSMicrophoneUsageDescription"], MICROPHONE_USAGE)
        self.assertEqual(self.info()["NSAppleEventsUsageDescription"], AUTOMATION_USAGE)
        result = self.verify()
        self.assertEqual(result["signing"], "ad-hoc, hardened runtime")
        self.assertIn(f"{ENGINE}/Versions/A/CTranscribe", result["files"])

    def test_a_bundle_carries_the_notices_and_each_licence_text(self):
        inventory = resources(ROOT)
        self.assertIn("THIRD_PARTY_NOTICES.md", inventory)
        for name in ("transcribe.cpp", "ggml", "miniz", "silero-vad", "Sparkle"):
            self.assertIn("Permission is hereby granted", inventory[f"Licenses/{name}.txt"].read_text())
        self.build()
        bundled = self.app / "Contents/Resources"
        self.assertEqual(
            (bundled / "THIRD_PARTY_NOTICES.md").read_bytes(), (ROOT / "THIRD_PARTY_NOTICES.md").read_bytes()
        )
        (bundled / "Licenses/ggml.txt").write_text("changed")
        with self.assertRaisesRegex(ValueError, "differs from source: Licenses/ggml.txt"):
            self.verify()

    def test_a_bundle_needs_the_engine_built_beside_the_binary(self):
        with self.assertRaisesRegex(ValueError, "missing CTranscribe.framework"):
            self.build(engine=False)

    def test_a_bundle_missing_any_part_fails_verification(self):
        self.build()
        with self.assertRaisesRegex(ValueError, "must link CTranscribe"):
            self.verify(linked=False)
        with self.assertRaisesRegex(ValueError, "the app must be signed with exactly"):
            self.verify(entitlements={LIBRARY_VALIDATION: True, AUDIO_INPUT: True})
        info = self.info()
        for key in ("NSAppleEventsUsageDescription", "NSMicrophoneUsageDescription"):
            for fault in ({}, {key: "another text"}):
                faulty = {name: value for name, value in info.items() if name != key} | fault
                (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(faulty))
                with self.subTest(key=key, fault=fault), self.assertRaisesRegex(ValueError, key):
                    self.verify()
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (self.app / ENGINE / "Versions/A/Headers").mkdir()
        with self.assertRaisesRegex(ValueError, "CTranscribe.framework still carries Headers"):
            self.verify()
        shutil.rmtree(self.app / ENGINE)
        with self.assertRaisesRegex(ValueError, "CTranscribe.framework is missing"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
