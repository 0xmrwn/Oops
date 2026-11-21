"""Attach completed isolated editor observations to a frozen OopsEval experiment."""

from pathlib import Path

from .comparison import ROLES, VERSION
from .records import canonical, digest, lines, load_run, lock, read_json, write_json


def import_lane(directory, role, path):
    with lock(directory / ".generation.lock"):
        experiment, manifest, cases, _ = load_run(directory)
        plan = read_json(directory / "config.json").get("comparison", {})
        if not experiment or plan.get("protocol") != VERSION or role not in ROLES or manifest["attempts"] != 1:
            raise ValueError("Import requires a registered single-attempt comparison.")
        file = plan["lanes"][role]
        destination = (directory / file).resolve()
        if destination.parent != (directory / "results").resolve() or Path(file).suffix != ".jsonl":
            raise ValueError("Registered lane must be a results file.")
        observations = lines(path)
        by_case = {r["case"]: r for r in observations}
        if len(observations) != len(by_case) or set(by_case) != set(cases):
            raise ValueError("Supply one observation or explicit failure for every frozen case.")
        rows = []
        models = set()
        for case in cases:
            observation = by_case[case]
            if observation["experiment"] != digest(experiment) or observation["role"] != role:
                raise ValueError("Observation does not belong to this experiment and role.")
            models.add(observation["model"])
            output, error = observation["output"], observation["error"]
            if not (isinstance(output, str) and error is None or output is None and isinstance(error, str) and error):
                raise ValueError("Supply applied editor text or a terminal failure.")
            rows.append(
                {
                    **observation,
                    "lane": "editor",
                    "provider": role,
                    "file": file,
                    "attempt": 1,
                    "verdict": "error" if error else "unscored",
                }
            )
        if len(models) != 1:
            raise ValueError("A lane must identify one build or model.")
        model = models.pop()
        if not isinstance(model, str) or not model.strip():
            raise ValueError("Every observation needs a nonempty model or build identifier.")
        if plan.get("purpose") == "qualification" and model != plan.get("models", {}).get(role):
            raise ValueError("Observed model differs from the registered build.")
        entry = {
            "file": file,
            "model": model,
            "resolved": model,
            "provider": role,
            "lane": "editor",
            "state": "done",
            "notes": [],
            "records": len(rows),
            "deferred": 0,
        }
        existing = [lane for lane in manifest["lanes"] if lane["file"] == file]
        if existing and existing != [entry]:
            raise ValueError("A different lane already owns the registered file.")
        contents = "".join(canonical(row) + "\n" for row in rows)
        if destination.exists() and destination.read_text() != contents:
            raise ValueError("Existing observations differ. Use a new comparison.")
        if not destination.exists():
            temporary = destination.with_suffix(".import.tmp")
            temporary.write_text(contents)
            temporary.chmod(0o600)
            temporary.replace(destination)
        if not existing:
            manifest["lanes"].append(entry)
            write_json(directory / "manifest.json", manifest)
        return {"role": role, "records": len(rows)}
