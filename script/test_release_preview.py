"""The preview build (OOPS_PREVIEW=1) is the only way the speech engine and the microphone reach a bundle."""

import os
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path

from release_bundle import MICROPHONE_USAGE, assemble, verify
from release_fakes import DEVELOPER_ID, FINGERPRINT, Builder, Inspector, Signer, preview_entitlements, stage
from release_signing import AUDIO_INPUT, ENGINE, FRAMEWORK, LIBRARY_VALIDATION, sign, verify_signature

ROOT = Path(__file__).resolve().parent.parent


class PreviewBundleTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.stage = Path(directory.name)
        self.app = self.stage / "Oops.app"

    def build(self, preview, engine=True):
        builder = Builder()
        assemble(ROOT, self.app, stage(self.stage, engine), "1.2.3", "42", builder, preview=preview)
        return builder

    def info(self):
        return plistlib.loads((self.app / "Contents/Info.plist").read_bytes())

    def verify(self, preview, **faults):
        return verify(ROOT, self.app, "1.2.3", "42", Inspector(self.app, **faults), preview=preview)

    def test_a_normal_bundle_leaves_the_engine_beside_the_binary_and_asks_for_no_microphone(self):
        builder = self.build(preview=False)
        self.assertFalse(os.path.lexists(self.app / ENGINE))
        self.assertNotIn("NSMicrophoneUsageDescription", self.info())
        self.assertEqual(sorted(builder.thinned), ["Autoupdate", "Sparkle"])
        self.assertEqual(self.verify(preview=False)["signing"], "ad-hoc, hardened runtime")

    def test_a_normal_bundle_with_any_of_the_three_fails_verification(self):
        self.build(preview=False)
        with self.assertRaisesRegex(ValueError, "must not link CTranscribe"):
            self.verify(preview=False, linked=True)
        with self.assertRaisesRegex(ValueError, "only a preview build's app may ask for the microphone"):
            self.verify(preview=False, entitlements={LIBRARY_VALIDATION: True, AUDIO_INPUT: True})
        info = self.info()
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info | {"NSMicrophoneUsageDescription": "x"}))
        with self.assertRaisesRegex(ValueError, "asks for the microphone"):
            self.verify(preview=False)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copytree(self.stage / "CTranscribe.framework", self.app / ENGINE, symlinks=True)
        with self.assertRaisesRegex(ValueError, "only for preview builds: Contents/Frameworks/CTranscribe.framework"):
            self.verify(preview=False)

    def test_a_preview_bundle_embeds_the_engine_trimmed_and_thinned_and_asks_for_the_microphone(self):
        builder = self.build(preview=True)
        engine = self.app / ENGINE
        self.assertTrue((engine / "Versions/A/CTranscribe").is_file())
        for name in ("Headers", "Modules"):
            self.assertFalse(os.path.lexists(engine / name), name)
            self.assertFalse(os.path.lexists(engine / "Versions/A" / name), name)
        self.assertEqual(sorted(builder.thinned), ["Autoupdate", "CTranscribe", "Sparkle"])
        self.assertEqual(self.info()["NSMicrophoneUsageDescription"], MICROPHONE_USAGE)
        result = self.verify(preview=True, linked=True, entitlements=preview_entitlements())
        self.assertIn(f"{ENGINE}/Versions/A/CTranscribe", result["files"])

    def test_a_preview_needs_the_engine_built_beside_the_binary(self):
        with self.assertRaisesRegex(ValueError, "missing CTranscribe.framework.*OOPS_PREVIEW=1"):
            self.build(preview=True, engine=False)

    def test_a_preview_bundle_missing_any_part_fails_verification(self):
        self.build(preview=True)
        with self.assertRaisesRegex(ValueError, "must link CTranscribe"):
            self.verify(preview=True, entitlements=preview_entitlements())
        with self.assertRaisesRegex(ValueError, "audio-input entitlement"):
            self.verify(preview=True, linked=True)
        info = self.info()
        del info["NSMicrophoneUsageDescription"]
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "NSMicrophoneUsageDescription"):
            self.verify(preview=True, linked=True, entitlements=preview_entitlements())
        (self.app / "Contents/Info.plist").write_bytes(
            plistlib.dumps(info | {"NSMicrophoneUsageDescription": MICROPHONE_USAGE})
        )
        (self.app / ENGINE / "Versions/A/Headers").mkdir()
        with self.assertRaisesRegex(ValueError, "CTranscribe.framework still carries Headers"):
            self.verify(preview=True, linked=True, entitlements=preview_entitlements())
        shutil.rmtree(self.app / ENGINE)
        with self.assertRaisesRegex(ValueError, "CTranscribe.framework is missing"):
            self.verify(preview=True, linked=True, entitlements=preview_entitlements())


class PreviewSigningTests(unittest.TestCase):
    app = Path("Oops.app")
    sparkle = [
        f"Oops.app/{FRAMEWORK}/Versions/B/Autoupdate",
        f"Oops.app/{FRAMEWORK}/Versions/B/Updater.app",
        f"Oops.app/{FRAMEWORK}",
    ]

    def test_normal_signing_never_adds_the_engine_or_the_audio_entitlement(self):
        for fingerprint in (None, FINGERPRINT):
            with self.subTest(fingerprint=fingerprint):
                signer = Signer()
                sign(self.app, fingerprint, signer)
                self.assertEqual(signer.signed, [*self.sparkle, "Oops.app"])
                self.assertNotIn(AUDIO_INPUT, signer.app_entitlements)

    def test_a_preview_signs_the_engine_after_sparkle_and_before_the_app_with_the_entitlement(self):
        for fingerprint in (None, FINGERPRINT):
            with self.subTest(fingerprint=fingerprint):
                signer = Signer()
                sign(self.app, fingerprint, signer, preview=True)
                self.assertEqual(signer.signed, [*self.sparkle, f"Oops.app/{ENGINE}", "Oops.app"])
                self.assertEqual(signer.app_entitlements, preview_entitlements(fingerprint))
                for command, entitlements in signer.calls:
                    self.assertNotIn("--deep", command)
                    self.assertIn("runtime", command)
                    if command[-1] != "Oops.app":
                        self.assertIsNone(entitlements)

    def test_a_preview_signed_with_developer_id_verifies_for_local_use(self):
        inspector = Inspector(self.app, entitlements={AUDIO_INPUT: True}, details=DEVELOPER_ID)
        self.assertEqual(
            verify_signature(self.app, FINGERPRINT, inspector, preview=True),
            "Developer ID, hardened runtime, secure timestamp",
        )
        with self.assertRaisesRegex(ValueError, "only a preview build's app"):
            verify_signature(self.app, FINGERPRINT, inspector)
        inspector.entitlements = {}
        with self.assertRaisesRegex(ValueError, "audio-input entitlement"):
            verify_signature(self.app, FINGERPRINT, inspector, preview=True)


if __name__ == "__main__":
    unittest.main()
