"""Fake bundles and tools for the preview build's packaging tests; nothing is compiled, signed or launched."""

import plistlib
import shutil
from pathlib import Path

from release_signing import AUDIO_INPUT, LIBRARY_VALIDATION

FINGERPRINT = "A" * 40
DEVELOPER_ID = "flags=0x10000(runtime)\nAuthority=Developer ID Application: Example\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Nov 4, 2026\n"
AD_HOC = "flags=0x10002(adhoc,runtime)\nSignature=adhoc\n"


def stage(directory, engine=True):
    """An executable with SwiftPM's frameworks beside it, as `swift build` leaves them (universal, with headers)."""
    binary = directory / "oops"
    binary.write_bytes(b"test executable")
    binary.chmod(0o755)
    frameworks = {"Sparkle": ("B", ("Sparkle", "Autoupdate", "Headers/S.h"))}
    if engine:
        frameworks["CTranscribe"] = ("A", ("CTranscribe", "Headers/transcribe.h", "Modules/module.modulemap"))
    for name, (version, files) in frameworks.items():
        framework = directory / f"{name}.framework"
        for file in files:
            path = framework / "Versions" / version / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\xca\xfe\xba\xbe universal")
            path.chmod(0o755)
        (framework / "Versions/Current").symlink_to(version)
        for top in {file.split("/")[0] for file in files}:
            (framework / top).symlink_to(f"Versions/Current/{top}")
    return binary


class Builder:
    """Stands in for ditto, lipo and actool while assembling; records what was thinned."""

    def __init__(self):
        self.thinned = []

    def __call__(self, command, *, capture=False):
        if command[0] == "ditto":
            shutil.copytree(command[1], command[2], symlinks=True)
        elif command[0] == "lipo":
            if command[1] == "-archs":
                return "x86_64 arm64"
            self.thinned.append(Path(command[1]).name)
        else:
            compiled = Path(command[command.index("--compile") + 1])
            for name in ("Assets.car", "Oops.icns"):
                (compiled / name).write_bytes(b"compiled")
            partial = Path(command[command.index("--output-partial-info-plist") + 1])
            partial.write_bytes(plistlib.dumps({"CFBundleIconName": "Oops", "CFBundleIconFile": "Oops"}))
        return ""


class Inspector:
    """Answers verification's lipo, otool, nm and codesign as a correctly built bundle would, or with one fault."""

    def __init__(self, app, linked=False, entitlements=None, details=AD_HOC):
        self.app, self.linked, self.details = str(app), linked, details
        self.entitlements = {LIBRARY_VALIDATION: True} if entitlements is None else entitlements

    def __call__(self, command, *, capture=False, stderr=False):
        if command[0] == "lipo":
            return "arm64"
        if command[0] == "otool":
            engine = " name @rpath/CTranscribe.framework/Versions/A/CTranscribe (offset 24)\n" if self.linked else ""
            return f" minos 26.0\n path @executable_path/../Frameworks (offset 12)\n{engine}"
        if "-dvvv" in command:
            return self.details
        if "--entitlements" in command:
            return plistlib.dumps(self.entitlements).decode() if command[-1] == self.app else ""
        return ""


def preview_entitlements(fingerprint=None):
    return ({} if fingerprint else {LIBRARY_VALIDATION: True}) | {AUDIO_INPUT: True}


class Signer:
    """Records each codesign call with the entitlements it was given, read before the temporary file goes."""

    def __init__(self):
        self.calls = []

    def __call__(self, command, **kwargs):
        entitlements = None
        if "--entitlements" in command:
            entitlements = plistlib.loads(Path(command[command.index("--entitlements") + 1]).read_bytes())
        self.calls.append((command, entitlements))

    @property
    def signed(self):
        return [command[-1] for command, _ in self.calls]

    @property
    def app_entitlements(self):
        return self.calls[-1][1] or {}
