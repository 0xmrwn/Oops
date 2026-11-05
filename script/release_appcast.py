"""Sparkle's update feed for a notarized release: the archive, its notes and the EdDSA-signed appcast.

The update archive is the notarized, stapled `Oops.zip` the release already verifies, renamed per version.
The branded DMG (D6) serves first downloads only; its step writes into the same publish folder and stays out
of the feed. Release notes are the `## VERSION` section of the CHANGELOG.md bundled in the app, never commits.
"""

import hashlib
import shutil
import xml.etree.ElementTree as ElementTree

from release_bundle import ARCHITECTURES, KEYCHAIN_ACCOUNT

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
DOWNLOADS = "https://github.com/0xmrwn/oops/releases/download/v{version}/"


def sparkle_tools(cache):
    """Sparkle's command-line tools, from the binary artifact SwiftPM resolved for the Release build."""
    tools = cache / ARCHITECTURES[0] / "artifacts/sparkle/Sparkle/bin"
    if not (tools / "generate_appcast").is_file():
        raise ValueError(f"Sparkle's tools are missing from {tools}; run a Release build first")
    return tools


def release_notes(changelog, version):
    """The `- ` entries under `## VERSION`; a heading still marked otherwise, like "(unreleased)", is refused."""
    entries, current, found = [], False, False
    for line in changelog.splitlines():
        line = line.strip()
        if line.startswith("## "):
            heading = line[3:].strip()
            current = heading.split(" ")[0] == version
            if current and heading != version:
                raise ValueError(
                    f"CHANGELOG.md has '## {heading}': rename it '## {version}' before building the release"
                )
            found = found or current
        elif current and line.startswith("- "):
            entries.append(line[2:])
    if not found:
        raise ValueError(f"CHANGELOG.md has no '## {version}' section")
    if not entries:
        raise ValueError(f"CHANGELOG.md lists nothing under '## {version}'")
    return entries


def write_feed(archive, version, build_number, notes, folder, prefix, tools, run, key_file=None):
    """Writes Oops-VERSION.zip, its notes and appcast.xml into the new folder; key_file '-' reads the key on stdin."""
    folder.mkdir()
    name = f"Oops-{version}"
    shutil.copyfile(archive, folder / f"{name}.zip")
    (folder / f"{name}.md").write_text("".join(f"- {entry}\n" for entry in notes))
    command = [str(tools / "generate_appcast"), "--download-url-prefix", prefix, "--embed-release-notes"]
    # One item, no deltas: each release's feed replaces the last at the same `latest` URL.
    command += ["--maximum-deltas", "0", "--maximum-versions", "1"]
    command += ["--ed-key-file", key_file] if key_file else ["--account", KEYCHAIN_ACCOUNT]
    run(command + [str(folder)])
    return check_feed(folder, version, build_number, notes, prefix)


def check_feed(folder, version, build_number, notes, prefix):
    """The feed names this version and build, links its archive by size and signature, and is signed itself."""
    name = f"Oops-{version}.zip"
    appcast = folder / "appcast.xml"
    items = ElementTree.parse(appcast).findall("./channel/item")
    if len(items) != 1:
        raise ValueError(f"appcast.xml should list exactly one update, found {len(items)}")
    item, enclosure = items[0], items[0].find("enclosure")
    if enclosure is None:
        raise ValueError("appcast.xml has no enclosure")
    build = item.findtext(f"{SPARKLE}version") or enclosure.get(f"{SPARKLE}version")
    short = item.findtext(f"{SPARKLE}shortVersionString") or enclosure.get(f"{SPARKLE}shortVersionString")
    if (build, short) != (build_number, version):
        raise ValueError(f"appcast.xml describes {short} ({build}), expected {version} ({build_number})")
    archive = folder / name
    if enclosure.get("url") != prefix + name or enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("appcast.xml enclosure does not match the archive's URL and size")
    if not enclosure.get(f"{SPARKLE}edSignature"):
        raise ValueError("appcast.xml enclosure has no EdDSA signature")
    description = item.find("description")
    if description is None or description.get(f"{SPARKLE}format") != "markdown":
        raise ValueError("appcast.xml should embed the release notes as Markdown")
    if any(entry not in (description.text or "") for entry in notes):
        raise ValueError("appcast.xml release notes differ from CHANGELOG.md")
    if "<!-- sparkle-signatures:" not in appcast.read_text():
        raise ValueError("appcast.xml is not signed (SURequireSignedFeed)")
    return {
        "appcast": str(appcast),
        "archive": str(archive),
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "url": prefix + name,
        "notes": len(notes),
    }


def appcast(root, cache, artifact, metadata, key_file, prefix, dry_run, run):
    if not metadata.get("distributable"):
        raise ValueError("the update feed needs a notarized artifact: run `just release notarize` first")
    version, build_number = metadata["version"], metadata["build_number"]
    prefix = prefix or DOWNLOADS.format(version=version)
    if not prefix.startswith("https://") or not prefix.endswith("/"):
        raise ValueError("download URL prefix must be an https:// folder URL ending in /")
    notes = release_notes((artifact / "Oops.app/Contents/Resources/CHANGELOG.md").read_text(), version)
    destination = root / "dist/publish" / f"oops-{version}-{build_number}"
    plan = {"artifact": str(artifact), "destination": str(destination), "url": prefix + f"Oops-{version}.zip"}
    if dry_run:
        return plan | {"notes": notes, "key": "--ed-key-file" if key_file else f"Keychain account {KEYCHAIN_ACCOUNT}"}
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"publish folder already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = destination.parent / f".stage-{destination.name}"
    if stage.exists():
        shutil.rmtree(stage)
    try:
        result = write_feed(
            artifact / "Oops.zip", version, build_number, notes, stage, prefix, sparkle_tools(cache), run, key_file
        )
        stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return plan | {key: value.replace(str(stage), str(destination)) for key, value in result.items() if key != "notes"}
