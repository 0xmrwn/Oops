#!/usr/bin/env python3
"""Local end-to-end update: Oops 0.1.0 updates itself to 0.1.1 from a localhost feed, then runs 0.1.1.

Both versions come from one Release compile, under the update test's bundle identifier
(dev.0xmrwn.oops.update-test), a localhost feed (local networking allowed by ATS for these builds only)
and a throwaway EdDSA key: the real Oops (its defaults, Keychain items, permissions and running instance)
and the real signing key are never touched. That copy runs only its updater (`Updates.runHarness`), which
downloads, installs and relaunches by itself: no keyboard or mouse input, no window. Stdout is JSON;
progress goes to stderr. Exit codes: 0 updated, 1 failed, 2 usage error.
"""

import argparse
import json
import os
import plistlib
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from release import CACHE, ROOT, compile_release, run
from release_appcast import release_notes, sparkle_tools, write_feed
from release_bundle import assemble
from release_signing import sign, validate_identity

IDENTIFIER = "dev.0xmrwn.oops.update-test"
OLD, NEW = ("0.1.0", "1"), ("0.1.1", "2")
CHANGELOG = (
    "## 0.1.1\n\n- Updates arrive in Settings → About.\n- The update test's second note.\n\n## 0.1.0\n\n- First.\n"
)
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def say(message):
    print(f"update test: {message}", file=sys.stderr, flush=True)


def throwaway_key(directory):
    """An Ed25519 pair for this run only (Sparkle's key file is the base64 seed); deleted with the run."""
    swift = (
        "import CryptoKit\nlet key = Curve25519.Signing.PrivateKey()\n"
        "print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())\n"
    )
    seed, public = subprocess.run(
        ["xcrun", "swift", "-"], input=swift, capture_output=True, text=True, check=True
    ).stdout.split()
    path = directory / "ed25519-seed"
    path.touch(mode=0o600)
    path.write_text(seed)
    return path, public


def build(binary, folder, version, build_number, feed, public_key, identity):
    app = folder / f"oops-{version}" / "Oops.app"
    settings = {
        "CFBundleIdentifier": IDENTIFIER,
        "SUFeedURL": feed,
        "SUPublicEDKey": public_key,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }
    assemble(ROOT, app, binary, version, build_number, run, settings)
    run(["xattr", "-cr", str(app)])
    sign(app, identity, run)
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    return app


def pids(app=None):
    """Processes running this copy's executable, or any update test's copy."""
    listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(" ")
        executable = command.split(" -", 1)[0]
        if (
            executable == f"{app}/Contents/MacOS/oops"
            if app
            else re.search(r"/oops-update-test-[^/]+/Applications/", command)
        ):
            found.append(int(pid))
    return found


def cdhash(target, field="CDHash"):
    """A field of the code signature of a bundle or a running process (by pid)."""
    details = subprocess.run(["codesign", "-dvvv", str(target)], capture_output=True, text=True).stderr
    match = re.search(rf"^{field}=(.+)$", details, re.M)
    return match.group(1) if match else None


def info(app):
    plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    return {key: plist.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")}


def listening(port):
    with socket.socket() as client:
        return client.connect_ex(("127.0.0.1", port)) == 0


def wait(condition, seconds, what):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.5)
    raise ValueError(f"timed out after {seconds}s waiting for {what}")


def clean_up(installed, server):
    for pid in pids(installed):
        os.kill(pid, signal.SIGTERM)
    try:
        wait(lambda: not pids(installed), 10, "the test copy to quit")
    except ValueError:
        for pid in pids(installed):
            os.kill(pid, signal.SIGKILL)
    if server:
        server.terminate()
    # The test copy's own defaults domain, caches and Launch Services record; nothing of the real Oops.
    subprocess.run(["defaults", "delete", IDENTIFIER], capture_output=True)
    library = Path.home() / "Library"
    for path in (
        library / "Caches" / IDENTIFIER,
        library / "HTTPStorages" / IDENTIFIER,
        library / "HTTPStorages" / f"{IDENTIFIER}.binarycookies",
        library / "Saved Application State" / f"{IDENTIFIER}.savedState",
        library / "Preferences" / f"{IDENTIFIER}.plist",
    ):
        subprocess.run(["rm", "-rf", str(path)])
    subprocess.run([LSREGISTER, "-u", str(installed)], capture_output=True)


def update_test(args):
    identity = validate_identity(args.signing_identity, run) if args.signing_identity else None
    if pids():
        raise ValueError(f"an update test's Oops is already running (pids {pids()})")
    binary = compile_release(args.jobs)
    # Resolved: processes report /private/var/…, not the /var/… symlink tempfile returns.
    work = Path(tempfile.mkdtemp(prefix="oops-update-test-")).resolve()
    installed, server = work / "Applications/Oops.app", None
    try:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        prefix = f"http://127.0.0.1:{port}/"
        key, public_key = throwaway_key(work)
        say(f"building {OLD[0]} ({OLD[1]}) and {NEW[0]} ({NEW[1]}) as {IDENTIFIER}, feed {prefix}appcast.xml")
        old = build(binary, work, *OLD, prefix + "appcast.xml", public_key, identity)
        new = build(binary, work, *NEW, prefix + "appcast.xml", public_key, identity)
        archive = work / "Oops.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(new), str(archive)])
        notes = release_notes(CHANGELOG, NEW[0])
        feed = write_feed(archive, *NEW, notes, work / "feed", prefix, sparkle_tools(CACHE), run, str(key))
        key.unlink()
        requests = work / "server.log"
        with requests.open("w") as log:
            server = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "http.server",
                    str(port),
                    "--bind",
                    "127.0.0.1",
                    "--directory",
                    str(work / "feed"),
                ],
                stdout=log,
                stderr=log,
            )
        wait(lambda: listening(port), 10, "the feed server")
        installed.parent.mkdir()
        run(["ditto", str(old), str(installed)])
        started = time.strftime("%Y-%m-%d %H:%M:%S")
        say(f"launching {OLD[0]} from {installed}")
        run(["/usr/bin/open", "-n", "-g", str(installed)])
        first = wait(lambda: pids(installed), 20, f"{OLD[0]} to start")[0]
        before = info(installed) | {"pid": first, "cdhash": cdhash(first)}
        if before["cdhash"] != cdhash(old):
            raise ValueError("the running app is not the 0.1.0 build")

        def relaunched():
            running = [pid for pid in pids(installed) if pid != first]
            return running and info(installed)["CFBundleShortVersionString"] == NEW[0] and running

        say("waiting for the download, install and relaunch")
        second = wait(relaunched, args.timeout, f"{NEW[0]} to replace {OLD[0]} and relaunch")[0]
        time.sleep(1)
        process = subprocess.run(
            ["ps", "-o", "pid=,lstart=,command=", "-p", str(second)], capture_output=True, text=True
        )
        after = info(installed) | {
            "pid": second,
            "cdhash": cdhash(second),
            "team": cdhash(second, "TeamIdentifier"),
            "ps": process.stdout.strip(),
        }
        if (after["CFBundleShortVersionString"], after["CFBundleVersion"]) != NEW:
            raise ValueError(f"installed bundle is {after}, expected {NEW}")
        if after["cdhash"] != cdhash(new) or cdhash(installed) != cdhash(new):
            raise ValueError("the relaunched process is not the signed 0.1.1 build")
        run(["codesign", "--verify", "--deep", "--strict", str(installed)])
        if first in pids(installed):
            raise ValueError(f"{OLD[0]} is still running")
        states = subprocess.run(
            [
                "/usr/bin/log",
                "show",
                "--style",
                "compact",
                "--start",
                started,
                "--predicate",
                f'subsystem == "{IDENTIFIER}"',
            ],
            capture_output=True,
            text=True,
        ).stdout
        states = re.findall(r"state: (.*)$", states, re.M)
        # The card's states, in order, with the CHANGELOG notes read from the signed feed.
        expected = [f"available {NEW[0]}, {len(notes)} notes", f"downloading {NEW[0]}", f"ready {NEW[0]}"]
        if states[:3] != expected:
            raise ValueError(f"the updater went through {states}, expected {expected}")
        return {
            "signing": "Developer ID" if identity else "ad-hoc",
            "feed": feed["url"].rsplit("/", 1)[0] + "/appcast.xml",
            "before": before,
            "after": after,
            "states": states,
            "requests": re.findall(r'"GET (\S+)', requests.read_text()),
            "work": str(work) if args.keep else None,
        }
    finally:
        clean_up(installed, server)
        if not args.keep:
            subprocess.run(["rm", "-rf", str(work)])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--signing-identity", help="Developer ID Application fingerprint; absent means ad-hoc")
    parser.add_argument("--jobs", type=int, default=4, help="Compiler jobs (default: 4)")
    parser.add_argument("--timeout", type=int, default=180, help="Seconds allowed for the update (default: 180)")
    parser.add_argument("--keep", action="store_true", help="Keep the temporary folder (apps, feed, server log)")
    args = parser.parse_args()
    try:
        print(json.dumps({"ok": True, "data": update_test(args)}, indent=2))
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        parser.exit(1)


if __name__ == "__main__":
    main()
