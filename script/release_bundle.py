"""Bundle assembly and offline verification for the local Release build."""

import hashlib
import os
import plistlib
import re
import shutil
from pathlib import Path

from release_signing import ENGINE, FRAMEWORK, verify_signature

BUNDLE_ID = "dev.0xmrwn.oops"
MINIMUM_OS = "26.0"
ARCHITECTURES = ("arm64",)
TOOLCHAIN = {"xcode": "27.0", "xcode_build": "27A266a", "sdk": "27.0"}
# Updates (D2). The private key lives only in the login Keychain (account KEYCHAIN_ACCOUNT) and GitHub secrets.
FEED_URL = "https://github.com/0xmrwn/oops/releases/latest/download/appcast.xml"
# Public by design: every copy of Oops carries it to check updates (the allow marks a scanner false positive).
PUBLIC_ED_KEY = "IaYgt0NpqjO3UjRn63dxbkxxhMS303EHgNHjg0aTOhw="  # gitleaks:allow
KEYCHAIN_ACCOUNT = "dev.0xmrwn.oops"
# Daily background checks without a consent prompt; downloads wait for the user's Update. The archive's
# EdDSA signature is checked before extraction, and the feed with its notes must be signed too.
UPDATE_SETTINGS = {
    "SUFeedURL": FEED_URL,
    "SUPublicEDKey": PUBLIC_ED_KEY,
    "SUEnableAutomaticChecks": True,
    "SUVerifyUpdateBeforeExtraction": True,
    "SURequireSignedFeed": True,
}
# Not needed by a non-sandboxed app at run time: the XPC services (sandboxed apps only) and build headers.
FRAMEWORK_EXTRAS = ("XPCServices", "Headers", "PrivateHeaders", "Modules")
# Only a preview build (OOPS_PREVIEW=1) carries the speech engine and asks for the microphone.
MICROPHONE_USAGE = "Oops listens while you dictate, and only then."


def validate_version(version, build_number):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("version must be three numeric components, e.g. 0.1.0")
    if not re.fullmatch(r"[1-9][0-9]*", build_number):
        raise ValueError("build number must be a positive integer; increase it for each published build")


def resources(root):
    result = {}
    groups = {
        "OopsIcon*.png": "",
        "Brand/*.pdf": "Brand",
        "Sounds/*.caf": "Sounds",
        "Sounds/Onboarding/*.caf": "Sounds/Onboarding",
        "Shaders/*.metal": "Shaders",
        "Gradient/*.bin": "Gradient",
    }
    for pattern, folder in groups.items():
        matches = sorted((root / "Resources").glob(pattern))
        if not matches:
            raise ValueError(f"missing required resources: Resources/{pattern}")
        for source in matches:
            result[str(Path(folder) / source.name)] = source
    for name in ("OopsIcon.png", "OopsIcon-dark.png"):
        if name not in result:
            raise ValueError(f"missing required resource: {name}")
    result["CHANGELOG.md"] = root / "CHANGELOG.md"
    for source in result.values():
        if not source.is_file() or source.is_symlink():
            raise ValueError(f"expected a regular resource file: {source}")
    return result


def machos(directory):
    """Mach-O executables and libraries under a directory, symlinks aside."""
    found = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink() or not path.is_file() or not path.stat().st_mode & 0o111:
            continue
        with path.open("rb") as file:
            if file.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                found.append(path)
    return found


def embed_sparkle(source, app, run):
    """SwiftPM's Sparkle.framework, trimmed to what runs here: arm64 code, no XPC services or headers."""
    if not (source / "Versions/B/Sparkle").is_file():
        raise ValueError(f"missing Sparkle.framework next to the executable: {source}")
    (app / FRAMEWORK).parent.mkdir(parents=True)
    embed(source, app / FRAMEWORK, "B", run)


def embed_engine(source, app, run):
    """transcribe.cpp's framework, trimmed the same way: arm64 code, no headers or module map."""
    if not (source / "Versions/A/CTranscribe").is_file():
        raise ValueError(
            f"missing CTranscribe.framework next to the executable (built without OOPS_PREVIEW=1?): {source}"
        )
    embed(source, app / ENGINE, "A", run)


def embed(source, framework, version, run):
    run(["ditto", str(source), str(framework)])
    for name in FRAMEWORK_EXTRAS:
        for path in (framework / name, framework / "Versions" / version / name):
            if path.is_symlink() or path.is_file():
                path.unlink()
            elif path.exists():
                shutil.rmtree(path)
    for code in machos(framework):
        if set(run(["lipo", "-archs", str(code)], capture=True).split()) != set(ARCHITECTURES):
            run(["lipo", str(code), "-thin", ARCHITECTURES[0], "-output", str(code)])


def assemble(root, app, binary, version, build_number, run, settings=None, preview=False):
    """settings: Info.plist entries replacing the defaults (the update test's identifier, feed and key)."""
    macos = app / "Contents/MacOS"
    destination = app / "Contents/Resources"
    macos.mkdir(parents=True)
    destination.mkdir()
    shutil.copy2(binary, macos / "oops")
    embed_sparkle(binary.parent / "Sparkle.framework", app, run)
    if preview:
        embed_engine(binary.parent / "CTranscribe.framework", app, run)
    for relative, source in resources(root).items():
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    partial = app.parent / "icon-info.plist"
    run(
        [
            "xcrun",
            "actool",
            str(root / "Resources/Oops.icon"),
            str(root / "Resources/Assets.xcassets"),
            "--compile",
            str(destination),
            "--output-format",
            "human-readable-text",
            "--platform",
            "macosx",
            "--minimum-deployment-target",
            MINIMUM_OS,
            "--app-icon",
            "Oops",
            "--output-partial-info-plist",
            str(partial),
        ]
    )
    info = {
        "CFBundleExecutable": "oops",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": "Oops",
        "CFBundleDisplayName": "Oops",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "LSMinimumSystemVersion": MINIMUM_OS,
        "LSUIElement": True,
        "NSPrincipalClass": "NSApplication",
        "NSAccessibilityUsageDescription": "Correct and revert text in the focused message composer when you press your Oops shortcuts.",
    }
    if preview:
        info["NSMicrophoneUsageDescription"] = MICROPHONE_USAGE
    info.update(UPDATE_SETTINGS)
    info.update(plistlib.loads(partial.read_bytes()))
    info.update(settings or {})
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    partial.unlink()


def verify_preview(app, info, preview):
    microphone = info.get("NSMicrophoneUsageDescription")
    if preview and microphone != MICROPHONE_USAGE:
        raise ValueError(f"Info.plist NSMicrophoneUsageDescription: expected {MICROPHONE_USAGE!r}, got {microphone!r}")
    if not preview:
        if microphone is not None:
            raise ValueError("Info.plist asks for the microphone, which only a preview build may")
        engine = [path for path in sorted(app.rglob("*")) if path.name.startswith("CTranscribe")]
        if engine:
            raise ValueError(f"the speech engine is only for preview builds: {engine[0].relative_to(app)}")


def hashes(app):
    """Every file's digest, and where each symlink (the framework's) points."""
    result = {}
    for file in sorted(app.rglob("*")):
        if file.is_symlink():
            result[str(file.relative_to(app))] = "-> " + os.readlink(file)
        elif file.is_file():
            result[str(file.relative_to(app))] = hashlib.sha256(file.read_bytes()).hexdigest()
    return result


def verify(root, app, version, build_number, run, signing_identity=None, preview=False):
    """preview: the bundle must carry the engine and the microphone; without it, either is a failure."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleExecutable": "oops",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "LSMinimumSystemVersion": MINIMUM_OS,
        "LSUIElement": True,
        "CFBundleIconName": "Oops",
        "CFBundleIconFile": "Oops",
    } | UPDATE_SETTINGS
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Info.plist {key}: expected {value!r}, got {info.get(key)!r}")
    verify_preview(app, info, preview)
    binary = app / "Contents/MacOS/oops"
    if not binary.stat().st_mode & 0o111:
        raise ValueError("app executable is not executable")
    arches = run(["lipo", "-archs", str(binary)], capture=True).split()
    if set(arches) != set(ARCHITECTURES):
        raise ValueError(f"expected Apple silicon only (arm64), got {arches}")
    for arch in ARCHITECTURES:
        commands = run(["otool", "-arch", arch, "-l", str(binary)], capture=True)
        if not re.search(r"\bminos 26\.0\b", commands):
            raise ValueError(f"{arch}: expected macOS 26.0 deployment target")
        if re.search(r"\bpath .*?(?:/\.build/|/Users/|/private/)", commands):
            raise ValueError(f"{arch}: executable contains a local build rpath")
        if "path @executable_path/../Frameworks " not in commands:
            raise ValueError(f"{arch}: executable cannot find Contents/Frameworks (rpath)")
        if ("CTranscribe" in commands) != preview:
            raise ValueError(f"{arch}: executable {'must' if preview else 'must not'} link CTranscribe.framework")
        symbols = run(["nm", "-arch", arch, str(binary)], capture=True)
        if any(name in symbols for name in ("AppProbe", "BrandSnapshots", "SetupSnapshots", "FramePacer")):
            raise ValueError(f"{arch}: debug-only implementation found in Release executable")
    frameworks = {FRAMEWORK: "Versions/B/Sparkle"} | ({ENGINE: "Versions/A/CTranscribe"} if preview else {})
    for relative, executable in frameworks.items():
        framework, name = app / relative, Path(relative).name
        if not (framework / executable).is_file():
            raise ValueError(f"{name} is missing from Contents/Frameworks")
        for extra in FRAMEWORK_EXTRAS:
            if (framework / extra).exists() or (framework / Path(executable).parent / extra).exists():
                raise ValueError(f"{name} still carries {extra}")
        for code in machos(framework):
            if set(run(["lipo", "-archs", str(code)], capture=True).split()) != set(ARCHITECTURES):
                raise ValueError(f"expected Apple silicon only (arm64): {code.relative_to(app)}")
    bundled = app / "Contents/Resources"
    for relative, source in resources(root).items():
        if (bundled / relative).read_bytes() != source.read_bytes():
            raise ValueError(f"bundled resource differs from source: {relative}")
    for compiled in ("Assets.car", "Oops.icns"):
        if not (bundled / compiled).stat().st_size:
            raise ValueError(f"missing compiled icon asset: {compiled}")
    signing = verify_signature(app, signing_identity, run, preview)
    return {
        "architectures": sorted(arches),
        "minimum_os": MINIMUM_OS,
        "signing": signing,
        "files": hashes(app),
    }
