"""Explicit local versus Developer ID signing; never exports a private key."""

import plistlib
import re
import tempfile

LOCAL_SIGNING = "ad-hoc, hardened runtime"
DISTRIBUTION_SIGNING = "Developer ID, hardened runtime, secure timestamp"
FRAMEWORK = "Contents/Frameworks/Sparkle.framework"
# Nested code, inside out: Sparkle's helpers, then the framework. Never --deep (Sparkle's guidance).
NESTED_CODE = (f"{FRAMEWORK}/Versions/B/Autoupdate", f"{FRAMEWORK}/Versions/B/Updater.app", FRAMEWORK)
# A preview build's speech engine (OOPS_PREVIEW=1), and the microphone it listens through under hardened runtime.
ENGINE = "Contents/Frameworks/CTranscribe.framework"
AUDIO_INPUT = "com.apple.security.device.audio-input"
LIBRARY_VALIDATION = "com.apple.security.cs.disable-library-validation"


def nested_code(preview):
    return (*NESTED_CODE, ENGINE) if preview else NESTED_CODE


def validate_identity(fingerprint, run):
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint):
        raise ValueError("signing identity must be a public 40-character certificate SHA-1 fingerprint")
    fingerprint = fingerprint.upper()
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True)
    if not any(fingerprint in line and '"Developer ID Application:' in line for line in identities.splitlines()):
        raise ValueError("the requested Developer ID Application identity is not usable in the local Keychain")
    return fingerprint


def sign(app, fingerprint, run, preview=False):
    command = ["codesign", "--force", "--sign", fingerprint or "-", "--options", "runtime"]
    command.append("--timestamp" if fingerprint else "--timestamp=none")
    for nested in nested_code(preview):
        run(command + [str(app / nested)])
    # Library validation only accepts frameworks from the app's own Team ID, which ad-hoc code lacks:
    # local builds may load their ad-hoc Sparkle. Developer ID builds never carry this (verify_signature),
    # and only a preview build asks for the microphone.
    entitlements = {LIBRARY_VALIDATION: True} if not fingerprint else {}
    if preview:
        entitlements[AUDIO_INPUT] = True
    if not entitlements:
        run(command + [str(app)])
        return
    with tempfile.NamedTemporaryFile("wb", suffix=".plist") as file:
        file.write(plistlib.dumps(entitlements))
        file.flush()
        run(command + ["--entitlements", file.name, str(app)])


def verify_signature(app, fingerprint, run, preview=False):
    command = ["codesign", "--verify", "--deep", "--strict"]
    if fingerprint:
        if not re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint):
            raise ValueError("invalid signing fingerprint in artifact metadata")
        requirement = (
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            f'and certificate leaf = H"{fingerprint}"'
        )
        command += ["-R", "=" + requirement]
    run(command + [str(app)])
    for code in (*nested_code(preview), ""):
        # The same signer, hardened runtime and timestamp for Sparkle's code as for the app.
        run(command + [str(app / code)])
        details = run(["codesign", "-dvvv", str(app / code)], capture=True, stderr=True)
        name = code or "the app"
        if not re.search(r"flags=0x[0-9a-f]+\([^)]*\bruntime\b", details):
            raise ValueError(f"Release signature must enable hardened runtime: {name}")
        if fingerprint:
            if "Authority=Developer ID Application:" not in details or not re.search(r"^Timestamp=.+", details, re.M):
                raise ValueError(
                    f"distribution signature must use Developer ID Application and a secure timestamp: {name}"
                )
            if not re.search(r"^TeamIdentifier=[A-Z0-9]{10}$", details, re.M):
                raise ValueError(f"distribution signature is missing an Apple developer Team ID: {name}")
        elif "Signature=adhoc" not in details:
            raise ValueError(f"expected ad-hoc signing for this local artifact: {name}")
        entitlements = run(["codesign", "-d", "--entitlements", "-", "--xml", str(app / code)], capture=True)
        entitlements = plistlib.loads(entitlements.encode()) if entitlements.strip() else {}
        if entitlements.get("com.apple.security.get-task-allow"):
            raise ValueError(f"Release must not allow debugger attachment via get-task-allow: {name}")
        if fingerprint and entitlements.get(LIBRARY_VALIDATION):
            raise ValueError(f"distribution signature must keep library validation: {name}")
        if preview and not code and entitlements.get(AUDIO_INPUT) is not True:
            raise ValueError("a preview build must be signed with the audio-input entitlement")
        if AUDIO_INPUT in entitlements and not (preview and not code):
            raise ValueError(f"only a preview build's app may ask for the microphone (audio-input): {name}")
    return DISTRIBUTION_SIGNING if fingerprint else LOCAL_SIGNING
