"""Shared disk contracts. Generation records stay immutable; judgments are attached by fingerprint."""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RUNS = Path.home() / "Library/Application Support/oops-eval/runs"


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def lines(path):
    path = Path(path)
    if not path.exists():
        return []
    raw = path.read_bytes()
    return journal_rows(raw, path.name)


def journal_rows(raw, name):
    rows, parts = [], raw.split(b"\n")
    for i, line in enumerate(parts):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            if i == len(parts) - 1 and not raw.endswith(b"\n"):
                break  # A writer may still be appending the last line.
            raise ValueError(f"Invalid JSONL at {name}:{i + 1}") from error
    return rows


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        temporary.chmod(0o600)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def append(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        previous = stream.read()
        journal_rows(previous, path.name)
        stream.seek(0, 2)
        if previous and not previous.endswith(b"\n"):
            tail_start = previous.rfind(b"\n") + 1
            try:
                json.loads(previous[tail_start:])
            except (json.JSONDecodeError, UnicodeDecodeError):
                stream.truncate(tail_start)
            else:
                stream.write(b"\n")
        stream.write((canonical(value) + "\n").encode())
        stream.flush()
        os.fsync(stream.fileno())


@contextlib.contextmanager
def lock(path):
    with Path(path).open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another judge process is already working on this run.") from error
        yield


def run_directory(root, name):
    if not name or Path(name).name != name or name in {".", ".."} or "\\" in name:
        raise ValueError("Run must be a folder name, not a path.")
    root = Path(root).expanduser().resolve()
    path = (root / name).resolve()
    if path.parent != root or not path.is_dir():
        raise ValueError("Run not found under the selected runs directory.")
    return path


def validate_snapshots(directory, experiment):
    if experiment.get("schema_version") != 2:
        raise ValueError(
            "This experiment lacks verified snapshots. Keep it as historical evidence and create a new run."
        )
    if experiment.get("kind", "generation") not in {"generation", "calibration"}:
        raise ValueError("Unsupported experiment kind.")
    snapshots = experiment.get("snapshots")
    required = {"cases.jsonl", "config.json"}
    if (directory / "prices.json").exists():
        required.add("prices.json")
    if not isinstance(snapshots, dict) or not required.issubset(snapshots):
        raise ValueError("Experiment snapshot hashes are missing.")
    root = directory.resolve()
    for name, expected in snapshots.items():
        calibration_result = (
            isinstance(name, str)
            and experiment.get("kind") == "calibration"
            and len(Path(name).parts) == 2
            and Path(name).parts[0] == "results"
            and Path(name).suffix == ".jsonl"
        )
        if (
            not isinstance(name, str)
            or not name
            or (Path(name).name != name and not calibration_result)
            or name in {".", ".."}
            or "\\" in name
            or not isinstance(expected, str)
        ):
            raise ValueError("Invalid experiment snapshot entry.")
        path = (root / name).resolve()
        if not path.is_relative_to(root) or path == root:
            raise ValueError("Experiment snapshot is outside the run directory.")
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Experiment snapshot is missing or changed: {name}. Restore it; do not mix evidence.")


def load_run(directory):
    directory = Path(directory)
    experiment = read_json(directory / "experiment.json") if (directory / "experiment.json").exists() else None
    manifest = read_json(directory / "manifest.json")
    case_path = directory / "cases.jsonl"
    if experiment is not None:
        validate_snapshots(directory, experiment)
    elif not case_path.exists():
        case_path = Path(manifest["cases"]).expanduser()
    cases = lines(case_path)
    if len({c["id"] for c in cases}) != len(cases):
        raise ValueError("Duplicate case IDs.")
    case_ids = {c["id"] for c in cases}
    attempts = manifest["attempts"]
    if type(attempts) is not int or attempts < 1:
        raise ValueError("The manifest needs a positive attempt count.")
    if experiment is not None and experiment.get("attempts", attempts) != attempts:
        raise ValueError("The manifest attempt count differs from the frozen experiment.")
    records = []
    for lane in manifest["lanes"]:
        path = (directory / lane["file"]).resolve()
        if not path.is_relative_to((directory / "results").resolve()):
            raise ValueError("Result file is outside this run's results folder.")
        seen = set()
        for row in lines(path):
            identity = (row["case"], row["attempt"])
            if row["case"] not in case_ids or type(row["attempt"]) is not int or not 1 <= row["attempt"] <= attempts:
                raise ValueError("A result names a case or attempt outside this experiment.")
            for field, expected in (
                ("run", manifest.get("run")),
                ("provider", lane.get("provider")),
                ("lane", lane.get("lane")),
                ("model", lane.get("resolved", lane.get("model"))),
            ):
                if field in row and expected is not None and row[field] != expected:
                    raise ValueError(f"A result's {field} differs from its manifest lane.")
            if identity in seen:
                raise ValueError(f"Duplicate result for {row['case']} attempt {row['attempt']}.")
            seen.add(identity)
            records.append({**row, "file": lane["file"]})
    return experiment, manifest, {c["id"]: c for c in cases}, records
