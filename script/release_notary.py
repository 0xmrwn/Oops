"""Resumable Apple submission and stapled ZIP output; source artifacts stay immutable."""

import fcntl
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path

from release_bundle import hashes, validate_version, verify


def file_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def notary_json(command, profile):
    result = subprocess.run(
        ["xcrun", "notarytool", *command, "--keychain-profile", profile, "--output-format", "json"],
        check=True,
        capture_output=True,
        text=True,
        timeout=180,
    )
    return json.loads(result.stdout)


def settle(work, submission_id, profile, wait_seconds, run):
    """Waits at most wait_seconds on a submission; None while Apple works on it, else its log once accepted."""
    if wait_seconds:
        # A timeout keeps the same submission ID. Never resubmit just because Apple's queue is slow.
        subprocess.run(
            [
                "xcrun",
                "notarytool",
                "wait",
                submission_id,
                "--keychain-profile",
                profile,
                "--timeout",
                f"{wait_seconds}s",
                "--output-format",
                "json",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=wait_seconds + 30,
        )
    status = notary_json(["info", submission_id], profile)
    write_json(work / "status.json", status)
    if status["status"] == "In Progress":
        return None
    log = work / "notary-log.json"
    run(["xcrun", "notarytool", "log", submission_id, str(log), "--keychain-profile", profile])
    if status["status"] != "Accepted":
        raise ValueError(
            f"Apple returned {status['status']}; inspect {log}; this submission will not be resubmitted automatically"
        )
    return log


def verify_distribution(root, artifact, metadata, run):
    archive = artifact / "Oops.zip"
    if file_digest(archive) != metadata["archive_sha256"]:
        raise ValueError("distribution ZIP differs from its recorded hash")
    run(["xcrun", "stapler", "validate", str(artifact / "Oops.app")])
    run(["syspolicy_check", "distribution", str(artifact / "Oops.app")])
    run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(artifact / "Oops.app")])
    # ZIP files cannot carry a stapled ticket themselves. Verify the app extracted from the final ZIP.
    with tempfile.TemporaryDirectory(prefix="oops-zip-check-", dir=root / ".build") as directory:
        extracted = Path(directory)
        run(["ditto", "-xk", str(archive), str(extracted)])
        result = verify(
            root,
            extracted / "Oops.app",
            metadata["version"],
            metadata["build_number"],
            run,
            metadata["signing_identity"],
        )
        if result != metadata["verification"]:
            raise ValueError("distribution ZIP contents differ from the verified stapled app")
        run(["xcrun", "stapler", "validate", str(extracted / "Oops.app")])


def notarize(root, artifact, metadata, profile, wait_seconds, dry_run, run):
    validate_version(metadata["version"], metadata["build_number"])
    if not metadata.get("signing_identity"):
        raise ValueError("notarization requires an artifact built with --signing-identity; ad-hoc signing is refused")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", profile):
        raise ValueError("use a Keychain profile name containing letters, numbers, dots, underscores or hyphens")
    if not 0 <= wait_seconds <= 60:
        raise ValueError("wait-seconds must be between 0 and 60; rerun the same command to resume")
    name = f"oops-{metadata['version']}-{metadata['build_number']}"
    destination = root / "dist/notarized" / name
    work = root / ".build/notarization" / name
    source_digest = file_digest(artifact / "build-info.json")
    if dry_run:
        return {
            "source_artifact": str(artifact),
            "destination": str(destination),
            "upload_to": "Apple notary service",
            "keychain_profile": profile,
        }
    for path in (root / ".build", work.parent, work, root / "dist", destination.parent, destination):
        if path.is_symlink():
            raise ValueError(f"notarization directories must not be symlinks: {path}")
    if destination.exists():
        final = json.loads((destination / "build-info.json").read_text())
        if final["notarization"]["source_metadata_sha256"] != source_digest:
            raise ValueError("existing distribution belongs to another source artifact")
        verify_distribution(root, destination, final, run)
        return {"artifact": str(destination), "status": "Accepted", "verified": True}
    work.mkdir(parents=True, exist_ok=True)
    with (work / "job.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("another notarization command is using this artifact") from error
        request_file = work / "request.json"
        if request_file.exists():
            request = json.loads(request_file.read_text())
            if request["source_metadata_sha256"] != source_digest:
                raise ValueError("pending submission belongs to different inputs; use a new build number")
            submission_id = str(uuid.UUID(request["id"]))
        else:
            # Stage from the already-verified immutable source for every new submission attempt.
            if (work / "Oops.app").exists():
                shutil.rmtree(work / "Oops.app")
            run(["ditto", str(artifact / "Oops.app"), str(work / "Oops.app")])
            if hashes(work / "Oops.app") != metadata["verification"]["files"]:
                raise ValueError("staging changed the signed app")
            archive = work / "submission.zip"
            archive.unlink(missing_ok=True)
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(work / "Oops.app"), str(archive)])
            response = notary_json(["submit", str(archive)], profile)
            submission_id = str(uuid.UUID(response["id"]))
            request = {
                "id": submission_id,
                "source_metadata_sha256": source_digest,
                "archive_sha256": file_digest(archive),
            }
            write_json(request_file, request)
        log = settle(work, submission_id, profile, wait_seconds, run)
        if log is None:
            return {
                "status": "In Progress",
                "submission_id": submission_id,
                "resume": "rerun the same notarize command",
            }
        # Restore the original signed payload on every finalization attempt, even after a partial staple.
        if (work / "Oops.app").exists():
            shutil.rmtree(work / "Oops.app")
        run(["ditto", str(artifact / "Oops.app"), str(work / "Oops.app")])
        run(["xcrun", "stapler", "staple", str(work / "Oops.app")])
        run(["xcrun", "stapler", "validate", str(work / "Oops.app")])
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".stage-", dir=destination.parent) as directory:
            stage = Path(directory)
            run(["ditto", str(work / "Oops.app"), str(stage / "Oops.app")])
            shutil.copyfile(log, stage / "notary-log.json")
            final = metadata | {
                "artifact": str(destination),
                "source_artifact": str(artifact),
                "distributable": True,
                "notarization": {"status": "Accepted", "id": submission_id, "source_metadata_sha256": source_digest},
            }
            final["verification"] = verify(
                root,
                stage / "Oops.app",
                metadata["version"],
                metadata["build_number"],
                run,
                metadata["signing_identity"],
            )
            run(
                [
                    "ditto",
                    "-c",
                    "-k",
                    "--sequesterRsrc",
                    "--keepParent",
                    str(stage / "Oops.app"),
                    str(stage / "Oops.zip"),
                ]
            )
            final["archive_sha256"] = file_digest(stage / "Oops.zip")
            verify_distribution(root, stage, final, run)
            write_json(stage / "build-info.json", final)
            stage.rename(destination)
        return {"artifact": str(destination), "status": "Accepted", "submission_id": submission_id, "verified": True}
