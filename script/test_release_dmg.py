"""DMG contracts: refusals with no external command, and a real (unsigned) image laid out and built."""

import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from release_bundle import hashes
from release_dmg import APP, build_image, dmg, window
from release_notary import file_digest

ROOT = Path(__file__).resolve().parent.parent
METADATA = {"version": "0.2.0", "build_number": "7", "distributable": True, "signing_identity": "A" * 40}


def run(command):
    subprocess.run(command, check=True)


class DmgTests(unittest.TestCase):
    def unexpected(self, *args, **kwargs):
        self.fail("No external command expected")

    def test_refusals_come_before_any_command(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for metadata, wait, message in (
                (METADATA | {"distributable": False}, 0, "needs a notarized artifact"),
                (METADATA, 61, "between 0 and 60"),
                (METADATA, 0, "run `just release appcast` first"),
            ):
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    dmg(root, root / "artifact", metadata, "oops-notary", wait, False, self.unexpected)

    def test_dry_run_names_the_publish_folder(self):
        plan = dmg(ROOT, ROOT / "artifact", METADATA, "oops-notary", 0, True, self.unexpected)
        self.assertTrue(plan["destination"].endswith("dist/publish/oops-0.2.0-7/Oops-0.2.0.dmg"))

    def test_a_failure_after_stapling_resumes_the_same_submission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact, work = root / "dist/notarized/oops-0.2.0-7", root / ".build/dmg/oops-0.2.0-7"
            for folder in (artifact, work, root / "dist/publish/oops-0.2.0-7"):
                folder.mkdir(parents=True)
            (artifact / "build-info.json").write_text("{}")
            (work / "Oops.dmg").write_bytes(b"submitted image")
            request = {
                "id": "11111111-1111-4111-8111-111111111111",
                "source_metadata_sha256": file_digest(artifact / "build-info.json"),
            }
            (work / "request.json").write_text(json.dumps(request | {"image_sha256": file_digest(work / "Oops.dmg")}))

            def staple(command):
                self.assertEqual(command[:3], ["xcrun", "stapler", "staple"])
                with open(command[3], "ab") as image:
                    image.write(b" + ticket")

            metadata = METADATA | {"verification": {"files": {}}}
            attempts = []

            def check(root, image, files, run):
                attempts.append(Path(image).read_bytes())
                if len(attempts) == 1:
                    raise ValueError("hdiutil attach failed")

            with (
                patch("release_dmg.settle", return_value=work / "notary-log.json"),
                patch("release_dmg.check_image", check),
            ):
                with self.assertRaisesRegex(ValueError, "attach failed"):
                    dmg(root, artifact, metadata, "oops-notary", 0, False, staple)
                result = dmg(root, artifact, metadata, "oops-notary", 0, False, staple)
            self.assertEqual(result["status"], "Accepted")
            self.assertEqual(attempts, [b"submitted image + ticket"] * 2)
            self.assertEqual((work / "Oops.dmg").read_bytes(), b"submitted image")
            self.assertEqual(
                (root / "dist/publish/oops-0.2.0-7/Oops-0.2.0.dmg").read_bytes(), b"submitted image + ticket"
            )

    def test_image_is_laid_out_from_the_app_link_and_window(self):
        # Never mounted here: an installer helper may offer to install any app on a disk image that appears.
        # `just release dmg` mounts the real image to check it (check_image).
        (ROOT / ".build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".build") as directory:
            work = Path(directory)
            (work / "Oops.app/Contents").mkdir(parents=True)
            (work / "Oops.app/Contents/Info.plist").write_text("payload")
            image = work / "Oops.dmg"
            build_image(ROOT, work / "Oops.app", image, run, work)
            volume = work / "volume"
            self.assertEqual({path.name for path in volume.iterdir()}, {APP, "Applications", *window(ROOT)})
            self.assertEqual(str((volume / "Applications").readlink()), "/Applications")
            self.assertEqual(hashes(volume / APP), hashes(work / "Oops.app"))
            # No Finder information or resource fork on the bundle (a hidden-extension flag is the former):
            # `codesign --strict` rejects both, and installers that copy the app with its attributes refuse it.
            attributes = subprocess.run(["xattr", str(volume / APP)], capture_output=True, check=True).stdout.split()
            self.assertFalse({b"com.apple.FinderInfo", b"com.apple.ResourceFork"} & set(attributes), attributes)
            for name, source in window(ROOT).items():
                self.assertEqual((volume / name).read_bytes(), source.read_bytes())
            info = plistlib.loads(
                subprocess.run(["hdiutil", "imageinfo", "-plist", str(image)], capture_output=True, check=True).stdout
            )
            self.assertEqual(info["Format"], "ULFO")


if __name__ == "__main__":
    unittest.main()
