"""Packaging contracts; no app launch, account access, or provider calls."""

import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from release_bundle import FRAMEWORK, UPDATE_SETTINGS, assemble, hashes, resources, validate_version, verify

ROOT = Path(__file__).resolve().parent.parent


class ReleaseTests(unittest.TestCase):
    def test_versions_are_safe_path_components_and_numeric_for_updates(self):
        validate_version("0.1.0", "1")
        validate_version("12.3.4", "12345")
        for version, number in (
            ("../app", "1"),
            ("v1.0.0", "1"),
            ("1.0.0-beta", "1"),
            ("01.0.0", "1"),
            ("1.0.0", "0"),
            ("1.0.0", "-1"),
            ("1.0.0", "1.2"),
        ):
            with self.subTest(version=version, number=number), self.assertRaises(ValueError):
                validate_version(version, number)

    def test_invalid_build_fails_before_toolchain_or_output_creation(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "script/release.py"), "build", "--version", "../escape", "--build-number", "1"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertIn("three numeric components", result.stdout)
        self.assertNotIn("Xcode", result.stderr)

    def test_cli_requires_explicit_version_and_build_number(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "script/release.py"), "build"], capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 2)

    def test_plan_keeps_cache_outside_swiftpm_configuration_links(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "script/release.py"), "plan", "--version", "0.1.0", "--build-number", "1"],
            capture_output=True,
            text=True,
            check=True,
        )
        data = json.loads(result.stdout)["data"]
        self.assertEqual(data["architectures"], ["arm64"])
        self.assertEqual(data["minimum_os"], "26.0")
        cache = Path(data["cache"])
        self.assertEqual(cache.parent, ROOT / ".build")
        self.assertNotIn(cache.name.lower(), ("debug", "release"))

    def test_inventory_includes_brand_onboarding_shader_and_notes(self):
        inventory = resources(ROOT)
        self.assertIn("OopsIcon-dark.png", inventory)
        self.assertIn("CHANGELOG.md", inventory)
        for folder in ("Brand/", "Sounds/Onboarding/", "Shaders/", "Gradient/"):
            self.assertTrue(any(name.startswith(folder) for name in inventory), folder)

    def test_missing_resource_group_is_a_failure(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            self.assertRaisesRegex(ValueError, "missing required resources"),
        ):
            resources(Path(directory))

    def test_verifier_rejects_intel_only_and_universal_executables(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Oops.app"
            binary = app / "Contents/MacOS/oops"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"executable inspected by lipo")
            binary.chmod(0o755)
            info = {
                "CFBundleIdentifier": "dev.0xmrwn.oops",
                "CFBundleExecutable": "oops",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "2",
                "LSMinimumSystemVersion": "26.0",
                "LSUIElement": True,
                "CFBundleIconName": "Oops",
                "CFBundleIconFile": "Oops",
            } | UPDATE_SETTINGS
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            for architectures in ("x86_64", "arm64 x86_64"):
                with self.subTest(architectures=architectures):

                    def inspect(command, *, capture=False, result=architectures):
                        self.assertEqual(command[:2], ["lipo", "-archs"])
                        return result

                    with self.assertRaisesRegex(ValueError, "expected Apple silicon only"):
                        verify(ROOT, app, "0.1.0", "2", inspect)

    def test_assembly_copies_the_inventory_and_merges_compiled_icon_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            binary = stage / "binary"
            binary.write_bytes(b"test executable")
            binary.chmod(0o755)

            framework = stage / "Sparkle.framework"
            for name in ("Sparkle", "Autoupdate", "XPCServices/Installer.xpc/Contents/MacOS/Installer", "Headers/S.h"):
                (framework / "Versions/B" / name).parent.mkdir(parents=True, exist_ok=True)
                (framework / "Versions/B" / name).write_bytes(b"\xca\xfe\xba\xbe universal")
                (framework / "Versions/B" / name).chmod(0o755)
            (framework / "Versions/Current").symlink_to("B")
            for name in ("Sparkle", "XPCServices", "Headers"):
                (framework / name).symlink_to(f"Versions/Current/{name}")
            thinned = []

            def compiler(command, *, capture=False):
                if command[0] == "ditto":
                    shutil.copytree(command[1], command[2], symlinks=True)
                elif command[0] == "lipo":
                    if command[1] == "-archs":
                        return "x86_64 arm64"
                    thinned.append(Path(command[1]).name)
                else:
                    partial = Path(command[command.index("--output-partial-info-plist") + 1])
                    partial.write_bytes(plistlib.dumps({"CFBundleIconName": "Oops", "CFBundleIconFile": "Oops"}))

            app = stage / "Oops.app"
            assemble(ROOT, app, binary, "1.2.3", "42", compiler, {"CFBundleIdentifier": "dev.0xmrwn.oops.test"})
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], "dev.0xmrwn.oops.test")
            for key, value in UPDATE_SETTINGS.items():
                self.assertEqual(info[key], value)
            embedded = app / FRAMEWORK
            self.assertEqual(sorted(thinned), ["Autoupdate", "Sparkle"])
            for name in ("XPCServices", "Headers"):
                self.assertFalse(os.path.lexists(embedded / name), name)
                self.assertFalse(os.path.lexists(embedded / "Versions/B" / name), name)
            self.assertEqual(hashes(app)[f"{FRAMEWORK}/Sparkle"], "-> Versions/Current/Sparkle")
            self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")
            self.assertEqual(info["CFBundleVersion"], "42")
            self.assertEqual(info["CFBundleIconName"], "Oops")
            self.assertEqual(info["LSMinimumSystemVersion"], "26.0")
            self.assertEqual((app / "Contents/MacOS/oops").read_bytes(), binary.read_bytes())
            for relative, source in resources(ROOT).items():
                self.assertEqual((app / "Contents/Resources" / relative).read_bytes(), source.read_bytes())


if __name__ == "__main__":
    unittest.main()
