"""Update feed contracts; no Keychain, network or Sparkle tool runs (the update test covers those)."""

import tempfile
import unittest
from pathlib import Path

from release_appcast import appcast, check_feed, release_notes, write_feed

CHANGELOG = """# Changelog

Intro with a - dash.

## 0.2.0

- Fix **one** sentence.
- Stats per hour.

## 0.1.0

- First.
"""
PREFIX = "https://github.com/0xmrwn/oops/releases/download/v0.2.0/"
NOTES = ["Fix **one** sentence.", "Stats per hour."]


def feed(size, build="7", version="0.2.0", signed=True, notes=NOTES, url=PREFIX + "Oops-0.2.0.zip"):
    description = "".join(f"- {entry}\n" for entry in notes)
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Oops</title><item><title>{version}</title>
<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<description sparkle:format="markdown"><![CDATA[{description}]]></description>
<enclosure url="{url}" length="{size}" type="application/octet-stream" sparkle:edSignature="c2lnbmF0dXJl"/>
</item></channel></rss>
"""
    return xml + ("<!-- sparkle-signatures:\nedSignature: abc\nlength: 1\n-->\n" if signed else "")


class AppcastTests(unittest.TestCase):
    def test_notes_are_the_versions_entries_only(self):
        self.assertEqual(release_notes(CHANGELOG, "0.2.0"), NOTES)
        self.assertEqual(release_notes(CHANGELOG, "0.1.0"), ["First."])

    def test_unreleased_missing_or_empty_sections_are_refused(self):
        for changelog, version, message in (
            (CHANGELOG.replace("## 0.2.0", "## 0.2.0 (unreleased)"), "0.2.0", "rename it '## 0.2.0'"),
            (CHANGELOG, "0.3.0", "no '## 0.3.0' section"),
            ("## 0.2.0\n\nNothing listed.\n", "0.2.0", "lists nothing"),
        ):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, message):
                release_notes(changelog, version)

    def test_feed_names_version_archive_signature_and_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "Oops-0.2.0.zip").write_bytes(b"zip" * 10)
            (folder / "appcast.xml").write_text(feed(30))
            result = check_feed(folder, "0.2.0", "7", NOTES, PREFIX)
            self.assertEqual(result["url"], PREFIX + "Oops-0.2.0.zip")
            for xml, message in (
                (feed(30, build="6"), "expected 0.2.0 \\(7\\)"),
                (feed(29), "URL and size"),
                (feed(30, url="https://elsewhere/Oops-0.2.0.zip"), "URL and size"),
                (feed(30, notes=["Something else."]), "release notes differ"),
                (feed(30, signed=False), "not signed"),
            ):
                (folder / "appcast.xml").write_text(xml)
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    check_feed(folder, "0.2.0", "7", NOTES, PREFIX)

    def test_generate_appcast_gets_one_item_embedded_notes_and_the_named_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "Oops.zip"
            archive.write_bytes(b"zip" * 10)
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                folder = Path(command[-1])
                self.assertEqual((folder / "Oops-0.2.0.md").read_text(), "- Fix **one** sentence.\n- Stats per hour.\n")
                (folder / "appcast.xml").write_text(feed(30))

            for key, expected in ((None, ["--account", "dev.0xmrwn.oops"]), ("-", ["--ed-key-file", "-"])):
                folder = root / f"feed-{key}"
                write_feed(archive, "0.2.0", "7", NOTES, folder, PREFIX, root / "bin", run, key)
                command = commands[-1]
                self.assertEqual(command[0], str(root / "bin/generate_appcast"))
                self.assertIn("--embed-release-notes", command)
                self.assertEqual(command[command.index("--maximum-deltas") + 1], "0")
                self.assertEqual(command[command.index("--download-url-prefix") + 1], PREFIX)
                self.assertEqual(command[-3:-1], expected)
                self.assertEqual((folder / "Oops-0.2.0.zip").read_bytes(), archive.read_bytes())

    def test_only_notarized_artifacts_get_a_feed(self):
        def unexpected(*args, **kwargs):
            self.fail("nothing may run")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = {"version": "0.2.0", "build_number": "7", "distributable": False}
            with self.assertRaisesRegex(ValueError, "notarized artifact"):
                appcast(root, root, root, metadata, None, None, True, unexpected)
            notes = root / "Oops.app/Contents/Resources/CHANGELOG.md"
            notes.parent.mkdir(parents=True)
            notes.write_text(CHANGELOG)
            metadata["distributable"] = True
            with self.assertRaisesRegex(ValueError, "https://"):
                appcast(root, root, root, metadata, None, "http://127.0.0.1:8000/", True, unexpected)
            plan = appcast(root, root, root, metadata, None, None, True, unexpected)
            self.assertEqual(plan["url"], PREFIX + "Oops-0.2.0.zip")
            self.assertEqual(plan["notes"], NOTES)
            self.assertEqual(plan["destination"], str(root / "dist/publish/oops-0.2.0-7"))


if __name__ == "__main__":
    unittest.main()
