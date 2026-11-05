"""The shells a case runs in: browsers with throwaway profiles, the app web view, Electron, and the
native, Catalyst, Qt and Swing apps. Each builds what it needs, starts once per run, and leaves nothing
behind (Safari, which has no throwaway profile, closes only its bake-off windows)."""

import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import setup

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
APPS = ROOT / ".build/bakeoff/apps"
CHROME = Path("/Applications/Google Chrome.app")
ZEN = Path("/Applications/Zen.app")
ZEN_PREFS = {
    "zen.welcome-screen.seen": True,
    "browser.shell.checkDefaultBrowser": False,
    "browser.aboutwelcome.enabled": False,
    "browser.startup.homepage_override.mstone": "ignore",
    "datareporting.policy.dataSubmissionPolicyBypassNotification": True,
    "app.update.auto": False,
}


def bundle(name, identifier, executable):
    """An .app around `executable` (a binary, or a launcher script), signed ad hoc."""
    app = APPS / f"{name}.app"
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    target = app / "Contents/MacOS" / name
    if isinstance(executable, Path):
        shutil.copy(executable, target)
    else:
        target.write_text(executable)
    target.chmod(0o755)
    info = {
        "CFBundleExecutable": name,
        "CFBundleIdentifier": identifier,
        "CFBundleName": f"oops bakeoff {name}",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def newer(target, sources):
    return target.exists() and all(target.stat().st_mtime >= s.stat().st_mtime for s in sources)


class Host:
    name = bundle_id = marker = ""
    first_load = 30

    def __init__(self, url):
        self.url = url
        self.process = None
        self.profile = None

    def page(self):
        return f"{self.url}page.html?host={self.name}"

    def activation(self):
        """What `activate` finds the shell's process by."""
        return self.marker

    def prepare(self):
        pass

    def start(self):
        raise NotImplementedError

    def stop(self):
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        if self.marker:
            subprocess.run(["pkill", "-f", self.marker], capture_output=True)
            time.sleep(0.5)
            subprocess.run(["pkill", "-9", "-f", self.marker], capture_output=True)
        if self.profile:
            shutil.rmtree(self.profile, ignore_errors=True)


class Chrome(Host):
    name, bundle_id = "chrome", "com.google.Chrome"

    def start(self):
        self.profile = Path(tempfile.mkdtemp(prefix="oops-bakeoff-chrome-"))
        self.marker = str(self.profile)
        options = [
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--window-size=1100,760",
            "--window-position=185,95",
        ]
        subprocess.run(
            ["open", "-na", str(CHROME), "--args", f"--user-data-dir={self.profile}", *options, f"--app={self.page()}"],
            check=True,
        )


class Zen(Host):
    name, bundle_id = "zen", "app.zen-browser.zen"

    def start(self):
        self.profile = Path(tempfile.mkdtemp(prefix="oops-bakeoff-zen-"))
        self.marker = str(self.profile)
        (self.profile / "user.js").write_text(
            "".join(f"user_pref({json.dumps(k)}, {json.dumps(v)});\n" for k, v in ZEN_PREFS.items())
        )
        subprocess.run(
            ["open", "-na", str(ZEN), "--args", "-profile", str(self.profile), "-no-remote", self.page()], check=True
        )
        time.sleep(3)  # Oops wakes Gecko once a window exists; see docs/compatibility.md.


class Safari(Host):
    name, bundle_id = "safari", "com.apple.Safari"

    def activation(self):
        return "Safari.app/Contents/MacOS/Safari"

    def start(self):
        self.was_running = subprocess.run(["pgrep", "-x", "Safari"], capture_output=True).returncode == 0
        script = f'tell application "Safari" to make new document with properties {{URL:"{self.page()}"}}'
        try:
            subprocess.run(["osascript", "-e", script], check=True, capture_output=True, text=True, timeout=15)
        except subprocess.CalledProcessError as error:
            raise RuntimeError(f"Safari could not open the fixture: {error.stderr.strip()}") from error
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                "Safari did not open the fixture within 15 seconds. Check its windows before retrying."
            ) from error

    def stop(self):
        if self.was_running:
            script = 'tell application "Safari" to close (every window whose name starts with "oops composer lab")'
        else:
            script = 'tell application "Safari" to quit'
        try:
            subprocess.run(["osascript", "-e", script], capture_output=True, timeout=10)
        except subprocess.TimeoutExpired:
            print("Safari did not close its fixture windows within 10 seconds; close them manually.", flush=True)


class WebKit(Host):
    name, bundle_id, marker = "webkit", "dev.0xmrwn.oops-bakeoff-webkit", "WebShell.app/Contents/MacOS/WebShell"

    def prepare(self):
        source, binary = HERE / "shells/WebShell.swift", APPS / "WebShell"
        if not newer(binary, [source]):
            APPS.mkdir(parents=True, exist_ok=True)
            subprocess.run(["swiftc", "-O", "-o", str(binary), str(source)], check=True)
        self.app = bundle("WebShell", self.bundle_id, binary)

    def start(self):
        subprocess.run(["open", "-n", str(self.app), "--args", self.page()], check=True)


class Electron(Host):
    name, bundle_id = "electron", "com.github.Electron"

    def prepare(self):
        self.app = setup.electron()

    def start(self):
        self.profile = Path(tempfile.mkdtemp(prefix="oops-bakeoff-electron-"))
        self.marker = str(self.profile)
        self.process = subprocess.Popen(
            [
                str(self.app / "Contents/MacOS/Electron"),
                str(HERE / "shells/electron"),
                f"--user-data-dir={self.profile}",
                self.page(),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


class Native(Host):
    name, bundle_id, marker = "native", "dev.0xmrwn.oops-bakeoff-native", "NativeShell.app/Contents/MacOS/NativeShell"
    first_load = 10

    def prepare(self):
        sources, binary = sorted((HERE / "native").glob("*.swift")), APPS / "NativeShell"
        if not newer(binary, sources):
            APPS.mkdir(parents=True, exist_ok=True)
            subprocess.run(["swiftc", "-O", "-o", str(binary), *map(str, sources)], check=True)
        self.app = bundle("NativeShell", self.bundle_id, binary)

    def start(self):
        subprocess.run(["open", "-n", str(self.app), "--args", self.url], check=True)


class Catalyst(Host):
    name, bundle_id, marker = (
        "catalyst",
        "dev.0xmrwn.oops-bakeoff-catalyst",
        "CatalystShell.app/Contents/MacOS/CatalystShell",
    )
    first_load = 15

    def prepare(self):
        sources, binary = sorted((HERE / "catalyst").glob("*.swift")), APPS / "CatalystShellBinary"
        sdk = subprocess.run(
            ["xcrun", "--show-sdk-path", "--sdk", "macosx"], capture_output=True, text=True, check=True
        ).stdout.strip()
        if not newer(binary, sources):
            APPS.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-O",
                    "-target",
                    "arm64-apple-ios18.0-macabi",
                    "-sdk",
                    sdk,
                    "-Fsystem",
                    f"{sdk}/System/iOSSupport/System/Library/Frameworks",
                    "-L",
                    f"{sdk}/System/iOSSupport/usr/lib",
                    "-o",
                    str(binary),
                    *map(str, sources),
                ],
                check=True,
            )
        self.app = bundle("CatalystShell", self.bundle_id, binary)
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        info.update(
            LSMinimumSystemVersion="15.0",
            UIDeviceFamily=[2, 6],
            UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": False},
        )
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True, capture_output=True)

    def start(self):
        subprocess.run(["open", "-n", str(self.app), "--args", self.url], check=True)


class Qt(Host):
    # The interpreter re-executes inside Python.app, so the process takes its bundle id.
    name, bundle_id, marker = "qt", "org.python.python", "toolkits/qt_shell.py"
    first_load = 15

    def prepare(self):
        site = setup.pyside()
        launcher = (
            f'#!/bin/sh\nexport PYTHONPATH="{site}"\nexec "{sys.executable}" "{HERE / "toolkits/qt_shell.py"}" "$@"\n'
        )
        self.app = bundle("QtShell", "dev.0xmrwn.oops-bakeoff-qt", launcher)

    def start(self):
        subprocess.run(["open", "-n", str(self.app), "--args", self.url], check=True)


class Swing(Host):
    name, bundle_id, marker = "swing", "dev.0xmrwn.oops-bakeoff-swing", "toolkits/SwingShell.java"
    first_load = 20

    def prepare(self):
        java = setup.jdk() / "bin/java"
        launcher = f'#!/bin/sh\nexec "{java}" -Dapple.awt.application.name="oops bakeoff swing" "{HERE / "toolkits/SwingShell.java"}" "$@"\n'
        self.app = bundle("SwingShell", self.bundle_id, launcher)

    def start(self):
        subprocess.run(["open", "-n", str(self.app), "--args", self.url], check=True)


HOSTS = {h.name: h for h in (Native, Catalyst, Qt, Swing, WebKit, Safari, Chrome, Zen, Electron)}


def host_of(case):
    """The shell a case runs in: its web shell, or the app its toolkit lives in."""
    if case["family"] == "web":
        return case["shell"]
    toolkit = case["toolkit"]
    return (
        "catalyst"
        if toolkit.startswith("catalyst")
        else "qt"
        if toolkit.startswith("qt")
        else "swing"
        if toolkit.startswith("swing")
        else "native"
    )


def installed(name):
    return {"chrome": CHROME, "zen": ZEN}.get(name, Path("/")).exists()
