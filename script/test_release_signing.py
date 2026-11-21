"""Distribution signing must fail closed; these tests never access Keychain."""

import plistlib
import unittest
from pathlib import Path

from release_fakes import Signer
from release_signing import (
    APPLE_EVENTS,
    AUDIO_INPUT,
    DISTRIBUTION_SIGNING,
    LIBRARY_VALIDATION,
    sign,
    validate_identity,
    verify_signature,
)

FINGERPRINT = "A" * 40
# Written out, not taken from release_signing: a change to what distribution signing asks for must fail here.
DISTRIBUTION_ENTITLEMENTS = {
    "com.apple.security.device.audio-input": True,
    "com.apple.security.automation.apple-events": True,
}
DETAILS = "flags=0x10000(runtime)\nAuthority=Developer ID Application: Example\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Nov 4, 2026\n"


class SigningTests(unittest.TestCase):
    def test_apple_development_is_not_a_distribution_identity(self):
        def identities(command, **kwargs):
            return f'1) {FINGERPRINT} "Apple Development: Example"'

        with self.assertRaisesRegex(ValueError, "not usable"):
            validate_identity(FINGERPRINT, identities)

    def test_valid_developer_id_fingerprint_is_normalized(self):
        self.assertEqual(
            validate_identity(
                FINGERPRINT.lower(), lambda *args, **kwargs: f'1) {FINGERPRINT} "Developer ID Application: Example"'
            ),
            FINGERPRINT,
        )

    def test_invalid_fingerprint_never_reaches_keychain(self):
        def unexpected(*args, **kwargs):
            self.fail("Keychain must not be queried")

        with self.assertRaises(ValueError):
            validate_identity("Developer ID Application: name", unexpected)

    def test_distribution_signing_requests_timestamp_without_deep_signing(self):
        signer = Signer()
        sign(Path("Oops.app"), FINGERPRINT, signer)
        for command, _ in signer.calls:
            self.assertIn("--timestamp", command)
            self.assertNotIn("--timestamp=none", command)
            self.assertNotIn("--deep", command)
            self.assertIn("runtime", command)

    def test_nested_code_is_signed_inside_out_before_the_app_and_without_entitlements(self):
        for fingerprint in (None, FINGERPRINT):
            with self.subTest(fingerprint=fingerprint):
                signer = Signer()
                sign(Path("Oops.app"), fingerprint, signer)
                self.assertEqual(
                    signer.signed,
                    [
                        "Oops.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
                        "Oops.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
                        "Oops.app/Contents/Frameworks/Sparkle.framework",
                        "Oops.app/Contents/Frameworks/CTranscribe.framework",
                        "Oops.app",
                    ],
                )
                self.assertEqual([entitlements is not None for _, entitlements in signer.calls], [False] * 4 + [True])

    def test_distribution_signing_asks_for_the_microphone_and_automation_and_nothing_else(self):
        signer = Signer()
        sign(Path("Oops.app"), FINGERPRINT, signer)
        self.assertEqual(signer.app_entitlements, DISTRIBUTION_ENTITLEMENTS)
        self.assertEqual({AUDIO_INPUT: True, APPLE_EVENTS: True}, DISTRIBUTION_ENTITLEMENTS)

    def test_only_local_builds_may_load_ad_hoc_frameworks(self):
        signer = Signer()
        sign(Path("Oops.app"), None, signer)
        self.assertEqual(signer.app_entitlements, DISTRIBUTION_ENTITLEMENTS | {LIBRARY_VALIDATION: True})
        entitlements = plistlib.dumps({LIBRARY_VALIDATION: True}).decode()
        with self.assertRaisesRegex(ValueError, "keep library validation"):
            verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect(entitlements=entitlements))

    def test_verification_refuses_an_app_with_an_entitlement_missing_or_added(self):
        for entitlements in (
            {},
            {APPLE_EVENTS: True},
            {AUDIO_INPUT: True},
            DISTRIBUTION_ENTITLEMENTS | {"com.apple.security.cs.allow-jit": True},
            DISTRIBUTION_ENTITLEMENTS | {AUDIO_INPUT: False},
        ):
            with (
                self.subTest(entitlements=entitlements),
                self.assertRaisesRegex(ValueError, "the app must be signed with exactly"),
            ):
                verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect(app=entitlements))

    def test_verification_refuses_nested_code_with_an_entitlement(self):
        entitlements = plistlib.dumps({AUDIO_INPUT: True}).decode()
        with self.assertRaisesRegex(ValueError, "Autoupdate must be signed with exactly \\[\\]"):
            verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect(entitlements=entitlements))

    def test_nested_code_without_hardened_runtime_is_refused(self):
        def details(path):
            return DETAILS.replace("(runtime)", "(none)") if path.endswith("Autoupdate") else DETAILS

        with self.assertRaisesRegex(ValueError, "hardened runtime: .*Autoupdate"):
            verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect(details))

    def inspect(self, details=DETAILS, entitlements=None, app=DISTRIBUTION_ENTITLEMENTS):
        """entitlements: what every piece of code answers with; otherwise the app alone carries `app`."""

        def run(command, **kwargs):
            if "--entitlements" in command:
                if entitlements is not None:
                    return entitlements
                return plistlib.dumps(app).decode() if command[-1] == "Oops.app" else ""
            if "-dvvv" in command:
                return details(command[-1]) if callable(details) else details
            self.assertIn(FINGERPRINT, " ".join(command))
            self.assertIn("1.2.840.113635.100.6.1.13", " ".join(command))
            return ""

        return run

    def test_signed_verification_pins_the_certificate_and_type(self):
        self.assertEqual(verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect()), DISTRIBUTION_SIGNING)

    def test_secure_timestamp_and_runtime_are_required(self):
        for details in (
            DETAILS.replace("Timestamp=Nov 4, 2026\n", ""),
            DETAILS.replace("flags=0x10000(runtime)", "flags=0x0(none)"),
        ):
            with self.subTest(details=details), self.assertRaises(ValueError):
                verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect(details))

    def test_debugger_entitlement_is_refused(self):
        entitlements = plistlib.dumps({"com.apple.security.get-task-allow": True}).decode()
        with self.assertRaisesRegex(ValueError, "debugger attachment"):
            verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect(entitlements=entitlements))


if __name__ == "__main__":
    unittest.main()
