#!/usr/bin/env python3
"""Fetches what the bake-off needs and the repository doesn't carry, at pinned versions and checksums.

  setup.py            Electron, a JDK (Swing) and PySide6 (Qt) into .build/bakeoff/runtimes (~700 MB)
  setup.py --vendor   rebuilds fixtures/bakeoff/vendor from engines/package.json (needs bun), so the
                      committed engine builds can be checked against their pinned sources

Downloads land in .build/bakeoff/cache and are verified before use; nothing is installed system-wide.
run.py calls the first form itself when a runtime is missing.
"""

import hashlib
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CACHE = ROOT / ".build/bakeoff/cache"
RUNTIMES = ROOT / ".build/bakeoff/runtimes"

ELECTRON = (
    "https://github.com/electron/electron/releases/download/v44.7.0/electron-v44.7.0-darwin-arm64.zip",
    "e04e411b58a0a14375dd21b0ab4a378fd38930a702e4e20e322fee4849404c0b",
)
JDK = (
    "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.8%2B9/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.8_9.tar.gz",
    "59422c2292ae4e76b87e00d8808dbe49cffa39af731e08bb0292ddb0af4e0261",
)
PYSIDE = [
    (
        "https://files.pythonhosted.org/packages/6f/16/0b7ecf89ebada82ed0430be33809ff325761ece83104f8635b1bd101fcd0/pyside6_essentials-6.11.2-cp310-abi3-macosx_13_0_universal2.whl",
        "77795c145202e65a78d88f7cd409d186e3ba23d159bdb3ba2dcd159ae5e5f0d9",
    ),
    (
        "https://files.pythonhosted.org/packages/47/44/11bf71c36e71936ab4e923e5dd23599dab527c4488b01860b0f689ce9947/shiboken6-6.11.2-cp310-abi3-macosx_13_0_universal2.whl",
        "53659683b1f7a08e9f87eff9b1065f1ceb7110cd7a4bc09fdf5efe43d286604d",
    ),
]

# name, entry, global, extra esbuild flags. Quill, Trix and RoosterJS ship browser builds: copied as-is.
BUNDLES = [
    ("tiptap", "BakeTiptap", []),
    ("lexical", "BakeLexical", []),
    ("slate", "BakeSlate", []),
    (
        "draft",
        "BakeDraft",
        ["--define:global=globalThis", "--alias:react=draft-react", "--alias:react-dom=draft-react-dom"],
    ),
    ("ckeditor", "BakeCKEditor", []),
    ("tinymce", "BakeTinyMCE", []),
    ("codemirror", "BakeCodeMirror", []),
    ("monaco", "BakeMonaco", ["--loader:.ttf=dataurl"]),
]
COPIES = {
    "quill/dist/quill.js": "quill.min.js",
    "quill/dist/quill.snow.css": "quill.snow.css",
    "trix/dist/trix.umd.min.js": "trix.min.js",
    "trix/dist/trix.css": "trix.css",
    "roosterjs/dist/rooster-min.js": "rooster.min.js",
    "draft-js/dist/Draft.css": "draft.css",
    "ckeditor5/dist/ckeditor5.css": "ckeditor.css",
}


def fetch(url, sha256):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / url.rsplit("/", 1)[1].replace("%2B", "+")
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != sha256:
        print(f"setup: downloading {path.name}", flush=True)
        with urllib.request.urlopen(url) as response, open(path.with_suffix(".part"), "wb") as out:
            shutil.copyfileobj(response, out)
        path.with_suffix(".part").replace(path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != sha256:
        path.unlink()
        sys.exit(f"setup: {path.name} has checksum {digest}, not the pinned {sha256}")
    return path


def electron():
    app = RUNTIMES / "electron/Electron.app"
    if not app.exists():
        archive = fetch(*ELECTRON)
        app.parent.mkdir(parents=True, exist_ok=True)
        # ditto keeps the framework symlinks and signatures that zipfile would flatten.
        subprocess.run(["ditto", "-x", "-k", str(archive), str(app.parent)], check=True)
    return app


def jdk():
    home = RUNTIMES / "jdk/Contents/Home"
    if not home.exists():
        archive = fetch(*JDK)
        target = RUNTIMES / "jdk"
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(target), "--strip-components", "1"], check=True)
    return home


def pyside():
    site = RUNTIMES / "pyside"
    done = site / ".complete"  # written only once both wheels are in: a half install starts over
    if not done.exists():
        shutil.rmtree(site, ignore_errors=True)
        for url, sha256 in PYSIDE:
            with zipfile.ZipFile(fetch(url, sha256)) as wheel:
                wheel.extractall(site)
        for library in site.rglob("*.so"):
            library.chmod(0o755)
        done.touch()
    return site


def vendor():
    work = ROOT / ".build/bakeoff/engines"
    work.mkdir(parents=True, exist_ok=True)
    shutil.copy(HERE / "engines/package.json", work / "package.json")
    shutil.copy(HERE / "engines/bun.lock", work / "bun.lock")
    subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=work, check=True)
    esbuild = work / "node_modules/.bin/esbuild"
    out = HERE / "vendor"
    # Template literals lowered to plain strings: no raw line ends, so no trailing whitespace for the
    # commit hooks to strip out of the engines' own strings.
    common = [
        "--bundle",
        "--minify",
        "--format=iife",
        "--legal-comments=none",
        "--log-level=warning",
        "--supported:template-literal=false",
    ]
    for name, global_name, extra in BUNDLES:
        subprocess.run(
            [
                str(esbuild),
                str(HERE / "engines/entries" / f"{name}.js"),
                *common,
                f"--global-name={global_name}",
                '--define:process.env.NODE_ENV="production"',
                *extra,
                f"--outfile={out / f'{name}.min.js'}",
            ],
            check=True,
            env={"NODE_PATH": str(work / "node_modules"), "PATH": "/usr/bin:/bin"},
        )
    for source, name in COPIES.items():
        data = (work / "node_modules" / source).read_bytes()
        (out / name).write_bytes(data if data.endswith(b"\n") else data + b"\n")  # as the commit hooks want it


def main():
    if "--vendor" in sys.argv:
        vendor()
        return
    print(f"setup: Electron at {electron()}\nsetup: JDK at {jdk()}\nsetup: PySide6 at {pyside()}")


if __name__ == "__main__":
    main()
