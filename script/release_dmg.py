"""The branded first-download DMG: the notarized app, an Applications link and the window from design/dmg.

The window's background and Finder layout are committed (design/dmg/render.sh makes them with dmgbuild), so
a release only copies them in and runs hdiutil. The image is signed, notarized and stapled on its own,
resumably like the app. It goes into the publish folder `appcast` wrote, and stays out of the update feed.
"""

import fcntl
import hashlib
import json
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path

from release_bundle import hashes
from release_notary import file_digest, notary_json, settle, write_json

VOLUME = "Oops"  # The layout finds its background through the volume name.
APP = "Oops.app"  # Finder's label, and the name the layout places.


def window(root):
    design = root / "design/dmg"
    return {".background.tiff": design / "background.tiff", ".DS_Store": design / "DS_Store"}


def build_image(root, app, image, run, work):
    """Lays out the volume from app and writes image (an APFS, LZFSE-compressed read-only DMG)."""
    stage = work / "volume"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    run(["ditto", str(app), str(stage / APP)])
    if hashes(stage / APP) != hashes(app):
        raise ValueError("staging changed the signed app")
    # No hidden-extension flag: it is a FinderInfo attribute on the bundle, which `codesign --strict` rejects,
    # and tools that copy the app with its attributes then refuse to install it. Finder hides `.app` anyway.
    (stage / "Applications").symlink_to("/Applications")
    for name, source in window(root).items():
        shutil.copyfile(source, stage / name)
    image.unlink(missing_ok=True)
    command = ["hdiutil", "create", "-quiet", "-fs", "APFS", "-format", "ULFO", "-volname", VOLUME]
    for attempt in range(3):  # hdiutil sometimes reports "Resource busy" on hosted runners.
        try:
            run(command + ["-srcfolder", str(stage), str(image)])
            break
        except subprocess.CalledProcessError:
            if attempt == 2:
                raise
            image.unlink(missing_ok=True)


def check_image(root, image, files, run, notarized=True):
    """The mounted volume holds exactly the verified app, the Applications link and the committed window."""
    if notarized:
        run(["codesign", "--verify", "--strict", "--verbose=2", str(image)])
        run(["xcrun", "stapler", "validate", str(image)])
        run(
            ["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(image)]
        )
    with tempfile.TemporaryDirectory(prefix="oops-dmg-check-", dir=root / ".build") as directory:
        mount = Path(directory) / "volume"
        run(
            [
                "hdiutil",
                "attach",
                "-quiet",
                "-nobrowse",
                "-readonly",
                "-noautoopen",
                "-mountpoint",
                str(mount),
                str(image),
            ]
        )
        try:
            names = {path.name for path in mount.iterdir()} - {".fseventsd"}
            expected = {APP, "Applications", *window(root)}
            if names != expected:
                raise ValueError(f"DMG volume holds {sorted(names)}, expected {sorted(expected)}")
            if not (mount / "Applications").is_symlink() or str((mount / "Applications").readlink()) != "/Applications":
                raise ValueError("DMG's Applications is not a link to /Applications")
            for name, source in window(root).items():
                if (mount / name).read_bytes() != source.read_bytes():
                    raise ValueError(f"DMG's {name} differs from design/dmg")
            if hashes(mount / APP) != files:
                raise ValueError("DMG's app differs from the verified notarized app")
            # The app as it sits on the image, attributes included: what an installer copies off it.
            run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(mount / APP)])
            if notarized:
                run(["xcrun", "stapler", "validate", str(mount / APP)])
        finally:
            run(["hdiutil", "detach", "-quiet", str(mount)])


def dmg(root, artifact, metadata, profile, wait_seconds, dry_run, run):
    if not metadata.get("distributable"):
        raise ValueError("the DMG needs a notarized artifact: run `just release notarize` first")
    if not 0 <= wait_seconds <= 60:
        raise ValueError("wait-seconds must be between 0 and 60; rerun to resume")
    version, build_number = metadata["version"], metadata["build_number"]
    name = f"oops-{version}-{build_number}"
    publish = root / "dist/publish" / name
    destination = publish / f"Oops-{version}.dmg"
    work = root / ".build/dmg" / name
    plan = {"artifact": str(artifact), "destination": str(destination), "upload_to": "Apple notary service"}
    if dry_run:
        return plan | {"keychain_profile": profile, "window": [str(path) for path in window(root).values()]}
    if not publish.is_dir():
        raise ValueError(f"run `just release appcast` first: the DMG goes into its folder, {publish}")
    files = metadata["verification"]["files"]
    if destination.exists():
        check_image(root, destination, files, run)
        return {"dmg": str(destination), "status": "Accepted", "verified": True}
    source_digest = file_digest(artifact / "build-info.json")
    image = work / "Oops.dmg"
    work.mkdir(parents=True, exist_ok=True)
    with (work / "job.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("another dmg command is using this artifact") from error
        request_file = work / "request.json"
        if request_file.exists():
            request = json.loads(request_file.read_text())
            if request["source_metadata_sha256"] != source_digest or file_digest(image) != request["image_sha256"]:
                raise ValueError(f"pending DMG submission belongs to other inputs; remove {work} to start over")
            submission_id = str(uuid.UUID(request["id"]))
        else:
            build_image(root, artifact / "Oops.app", image, run, work)
            run(["codesign", "--force", "--timestamp", "--sign", metadata["signing_identity"], str(image)])
            submission_id = str(uuid.UUID(notary_json(["submit", str(image)], profile)["id"]))
            request = {"id": submission_id, "source_metadata_sha256": source_digest, "image_sha256": file_digest(image)}
            write_json(request_file, request)
        if settle(work, submission_id, profile, wait_seconds, run) is None:
            return {"status": "In Progress", "submission_id": submission_id, "resume": "rerun the same dmg command"}
        # The submitted image stays as Apple saw it, so a failure past this point can rerun the same command.
        stapled = work / "Oops-stapled.dmg"
        shutil.copyfile(image, stapled)
        run(["xcrun", "stapler", "staple", str(stapled)])
        check_image(root, stapled, files, run)
        staged = publish / f".{destination.name}"
        shutil.copyfile(stapled, staged)
        staged.rename(destination)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    return {"dmg": str(destination), "sha256": digest, "status": "Accepted", "submission_id": submission_id}
