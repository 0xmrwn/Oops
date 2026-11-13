#!/usr/bin/env python3
"""Build a local Apple silicon Release bundle without installing or launching Oops."""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from release_bundle import ARCHITECTURES, MINIMUM_OS, TOOLCHAIN, assemble, validate_version, verify
from release_signing import DISTRIBUTION_SIGNING, LOCAL_SIGNING, sign, validate_identity

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".build/packaging"


def run(command, *, capture=False, stderr=False):
    result = subprocess.run(
        command,
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else sys.stderr,
        stderr=subprocess.PIPE if capture and stderr else None,
    )
    return result.stderr if stderr else result.stdout


def input_digest():
    digest = hashlib.sha256()
    files = [ROOT / "Package.swift", ROOT / "CHANGELOG.md"]
    files.extend(
        ROOT / "script" / name
        for name in (
            "release.py",
            "release_bundle.py",
            "release_signing.py",
            "release_notary.py",
            "release_appcast.py",
            "release_dmg.py",
            "release_debug_check.swift",
        )
    )
    if (ROOT / "Package.resolved").is_file():
        files.append(ROOT / "Package.resolved")
    for directory in ("Sources", "Resources"):
        files.extend(file for file in (ROOT / directory).rglob("*") if file.is_file())
    for file in sorted(files):
        digest.update(str(file.relative_to(ROOT)).encode() + b"\0" + file.read_bytes() + b"\0")
    return digest.hexdigest()


def toolchain():
    xcode = run(["xcodebuild", "-version"], capture=True).splitlines()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], capture=True).strip()
    actual = {
        "xcode": xcode[0].removeprefix("Xcode "),
        "xcode_build": xcode[1].removeprefix("Build version "),
        "sdk": sdk,
    }
    if actual != TOOLCHAIN:
        raise ValueError(
            f"Release toolchain mismatch: expected {TOOLCHAIN}, found {actual}; select the pinned Xcode with DEVELOPER_DIR"
        )
    swift = run(["xcrun", "swift", "--version"], capture=True).strip()
    if "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)" not in swift:
        raise ValueError("Release requires the Swift compiler bundled with Xcode 27.0; check TOOLCHAINS")
    return actual | {"swift": swift}


def options():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Exit codes: 0 success, 1 verification/build failure, 2 usage error. JSON results on stdout; compiler logs on stderr.",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("build", "plan"):
        command = sub.add_parser(
            name, help="Build the bundle" if name == "build" else "Preview inputs and output without building"
        )
        version = command.add_mutually_exclusive_group(required=True)
        version.add_argument("--version", help="Numeric release version, e.g. 0.1.0")
        version.add_argument(
            "--from-tag", action="store_true", help="Use the exact vMAJOR.MINOR.PATCH tag at a clean HEAD"
        )
        command.add_argument(
            "--build-number", required=True, help="Positive integer; must increase for published updates"
        )
        command.add_argument("--jobs", type=int, default=4, help="Compiler jobs per architecture (default: 4)")
        command.add_argument("--dry-run", action="store_true", help="Preview only, like plan")
        command.add_argument(
            "--signing-identity",
            help="Developer ID Application certificate fingerprint; absent means local ad-hoc signing",
        )
        command.add_argument(
            "--preview",
            action="store_true",
            help="OOPS_PREVIEW=1: embed the speech engine and ask for the microphone; for this Mac only, never distributed",
        )
    command = sub.add_parser(
        "verify", help="Verify an existing local Release artifact against its hashes and this checkout"
    )
    command.add_argument(
        "--artifact", required=True, type=Path, help="Artifact directory containing Oops.app and build-info.json"
    )
    command = sub.add_parser("notarize", help="Submit a signed artifact to Apple, resume it, and produce a stapled ZIP")
    command.add_argument("--artifact", required=True, type=Path)
    command.add_argument(
        "--keychain-profile", required=True, help="notarytool Keychain profile; never pass a password here"
    )
    command.add_argument(
        "--wait-seconds", type=int, default=30, help="Bounded wait per invocation (0–60 seconds); rerun to resume"
    )
    command.add_argument(
        "--dry-run", action="store_true", help="Verify inputs and preview Apple upload/output; no network or mutations"
    )
    command = sub.add_parser(
        "appcast",
        help="Write the update archive and EdDSA-signed appcast.xml for a notarized artifact into dist/publish/",
    )
    command.add_argument("--artifact", required=True, type=Path, help="Notarized artifact directory (dist/notarized/…)")
    command.add_argument(
        "--ed-key-file",
        help="Private EdDSA key file, or '-' for standard input (CI); absent means the login Keychain item",
    )
    command.add_argument(
        "--download-url-prefix", help="Folder URL the archive is served from (default: the tag's GitHub release)"
    )
    command.add_argument("--dry-run", action="store_true", help="Verify inputs and preview the feed; writes nothing")
    command = sub.add_parser(
        "dmg", help="Write the signed, notarized first-download DMG into the publish folder `appcast` wrote"
    )
    command.add_argument("--artifact", required=True, type=Path, help="Notarized artifact directory (dist/notarized/…)")
    command.add_argument(
        "--keychain-profile", required=True, help="notarytool Keychain profile; never pass a password here"
    )
    command.add_argument(
        "--wait-seconds", type=int, default=30, help="Bounded wait per invocation (0–60 seconds); rerun to resume"
    )
    command.add_argument("--dry-run", action="store_true", help="Verify inputs and preview the DMG; writes nothing")
    return parser, parser.parse_args()


def build(args):
    version = args.version
    if args.from_tag:
        if run(["git", "status", "--porcelain"], capture=True).strip():
            raise ValueError("--from-tag requires a clean checkout")
        version = (
            run(["git", "describe", "--tags", "--exact-match", "--match", "v[0-9]*", "HEAD"], capture=True)
            .strip()
            .removeprefix("v")
        )
    validate_version(version, args.build_number)
    if args.jobs < 1:
        raise ValueError("jobs must be positive")
    fingerprint = validate_identity(args.signing_identity, run) if args.signing_identity else None
    output = ROOT / "dist/release" / f"oops-{version}-{args.build_number}{'-preview' if args.preview else ''}"
    metadata = {
        "version": version,
        "build_number": args.build_number,
        "configuration": "release",
        "source_revision": run(["git", "rev-parse", "HEAD"], capture=True).strip(),
        "source_dirty": bool(run(["git", "status", "--porcelain"], capture=True).strip()),
        "input_sha256": input_digest(),
        "toolchain": toolchain(),
        "artifact": str(output),
        "cache": str(CACHE),
        "architectures": list(ARCHITECTURES),
        "minimum_os": MINIMUM_OS,
        "signing": DISTRIBUTION_SIGNING if fingerprint else LOCAL_SIGNING,
        "signing_identity": fingerprint,
        "distributable": False,
        "preview": args.preview,
    }
    if args.command == "plan" or args.dry_run:
        return metadata
    if output.exists() or output.is_symlink():
        raise ValueError(f"artifact already exists: {output}; use verify or choose a new build number")
    if (ROOT / "dist").is_symlink() or output.parent.is_symlink():
        raise ValueError("Release output directories must not be symlinks")
    binary = compile_release(args.jobs, args.preview)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".stage-", dir=output.parent) as directory:
        stage = Path(directory)
        app = stage / "Oops.app"
        assemble(ROOT, app, binary, version, args.build_number, run, preview=args.preview)
        run(["xattr", "-cr", str(app)])
        sign(app, fingerprint, run, args.preview)
        metadata["verification"] = verify(ROOT, app, version, args.build_number, run, fingerprint, args.preview)
        verify_debug_flags(CACHE, args.preview)
        if input_digest() != metadata["input_sha256"]:
            raise ValueError("build inputs changed while compiling; retry with stable inputs")
        (stage / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
        stage.rename(output)
    return metadata


def compile_release(jobs, preview=False):
    """The Release executable (arm64), with Sparkle.framework beside it (and CTranscribe.framework in a preview);
    also used by the update test."""
    # SwiftPM owns .build/debug and .build/release and replaces them with configuration symlinks.
    cache = CACHE
    if cache.is_symlink():
        raise ValueError("Release cache directory must not be a symlink")
    cache.mkdir(parents=True, exist_ok=True)
    os.environ["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang-cache")
    # Package.swift reads the option; only --preview sets it, whatever the calling shell exported.
    os.environ.pop("OOPS_PREVIEW", None)
    if preview:
        os.environ["OOPS_PREVIEW"] = "1"
    binaries = []
    for arch in ARCHITECTURES:
        command = [
            "xcrun",
            "swift",
            "build",
            "--disable-sandbox",
            "--configuration",
            "release",
            "--product",
            "oops",
            "--scratch-path",
            str(cache / (f"{arch}-preview" if preview else arch)),
            "--cache-path",
            str(cache / "cache"),
            "--config-path",
            str(cache / "config"),
            "--security-path",
            str(cache / "security"),
            "--triple",
            f"{arch}-apple-macosx{MINIMUM_OS}",
            "--jobs",
            str(jobs),
            "--disable-local-rpath",
            # Public dependencies only: a Keychain lookup for github.com can wait on a hidden prompt.
            "--disable-keychain",
        ]
        run(command)
        binaries.append(Path(run(command + ["--show-bin-path"], capture=True).strip()) / "oops")
    return binaries[0]


def verify_debug_flags(cache, preview=False):
    executable = cache / "check-debug-flags"
    run(
        [
            "xcrun",
            "swiftc",
            "-O",
            "-parse-as-library",
            "-warnings-as-errors",
            *(["-D", "OOPS_PREVIEW"] if preview else []),
            str(ROOT / "Sources/Oops/Debug/DebugFlags.swift"),
            str(ROOT / "script/release_debug_check.swift"),
            "-o",
            str(executable),
        ]
    )
    run([str(executable), "--brand-review", "--hello-only", "--settings"])


def check_artifact(artifact, command, run):
    """An artifact's metadata, once its files match it and this checkout. Only `verify` takes a preview build:
    every step towards users verifies without the option, so the engine or the microphone fails it."""
    metadata = json.loads((artifact / "build-info.json").read_text())
    if input_digest() != metadata["input_sha256"]:
        raise ValueError("checkout build inputs differ from the artifact; verify using its source checkout")
    preview = command == "verify" and metadata.get("preview", False)
    if metadata.get("preview") and not preview:
        raise ValueError(f"{command} refuses a preview build (--preview): it is for this Mac only")
    result = verify(
        ROOT,
        artifact / "Oops.app",
        metadata["version"],
        metadata["build_number"],
        run,
        metadata.get("signing_identity"),
        preview,
    )
    if result != metadata["verification"]:
        raise ValueError("artifact files differ from build-info.json")
    if metadata.get("distributable"):
        from release_notary import verify_distribution

        verify_distribution(ROOT, artifact, metadata, run)
    return metadata


def main():
    parser, args = options()
    try:
        if args.command in ("verify", "notarize", "appcast", "dmg"):
            artifact = args.artifact.resolve()
            metadata = check_artifact(artifact, args.command, run)
            result = {"artifact": str(artifact), "verified": True}
            if args.command == "notarize":
                from release_notary import notarize

                result = notarize(ROOT, artifact, metadata, args.keychain_profile, args.wait_seconds, args.dry_run, run)
            if args.command == "appcast":
                from release_appcast import appcast

                result = appcast(
                    ROOT, CACHE, artifact, metadata, args.ed_key_file, args.download_url_prefix, args.dry_run, run
                )
            if args.command == "dmg":
                from release_dmg import dmg

                result = dmg(ROOT, artifact, metadata, args.keychain_profile, args.wait_seconds, args.dry_run, run)
        else:
            result = build(args)
        print(json.dumps({"ok": True, "data": result}, indent=2))
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        parser.exit(1)


if __name__ == "__main__":
    main()
