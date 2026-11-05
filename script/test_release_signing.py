"""Distribution signing must fail closed; these tests never access Keychain."""

import plistlib
import unittest
from pathlib import Path

from release_signing import DISTRIBUTION_SIGNING, LIBRARY_VALIDATION, sign, validate_identity, verify_signature

FINGERPRINT = "A" * 40
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
        commands = []
        sign(Path("Oops.app"), FINGERPRINT, commands.append)
        for command in commands:
            self.assertIn("--timestamp", command)
            self.assertNotIn("--timestamp=none", command)
            self.assertNotIn("--deep", command)
            self.assertIn("runtime", command)

    def test_sparkle_is_signed_inside_out_before_the_app(self):
        commands = []
        sign(Path("Oops.app"), None, commands.append)
        signed = [command[-1] for command in commands]
        self.assertEqual(
            signed,
            [
                "Oops.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
                "Oops.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
                "Oops.app/Contents/Frameworks/Sparkle.framework",
                "Oops.app",
            ],
        )

    def test_only_local_builds_may_load_ad_hoc_frameworks(self):
        local, distribution = [], []
        sign(Path("Oops.app"), None, local.append)
        sign(Path("Oops.app"), FINGERPRINT, distribution.append)
        self.assertEqual([("--entitlements" in command) for command in local], [False, False, False, True])
        self.assertFalse(any("--entitlements" in command for command in distribution))
        entitlements = plistlib.dumps({LIBRARY_VALIDATION: True}).decode()
        with self.assertRaisesRegex(ValueError, "keep library validation"):
            verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect(entitlements=entitlements))

    def test_nested_code_without_hardened_runtime_is_refused(self):
        def details(path):
            return DETAILS.replace("(runtime)", "(none)") if path.endswith("Autoupdate") else DETAILS

        with self.assertRaisesRegex(ValueError, "hardened runtime: .*Autoupdate"):
            verify_signature(Path("Oops.app"), FINGERPRINT, self.inspect(details))

    def inspect(self, details=DETAILS, entitlements=""):
        def run(command, **kwargs):
            if "--entitlements" in command:
                return entitlements
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
