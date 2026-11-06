#!/usr/bin/env python3
"""Compare optimized synchronous Stats.load on synthetic histories, without launching Oops."""

import argparse
import hashlib
import json
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "Sources/Oops/App/Stats.swift"
MAIN = r"""import Foundation
import CryptoKit

enum DebugFlags { static let sampleStats = false; static let stubProvider: URL? = nil }

extension Stats {
    static func probeLoad(_ file: URL) -> [Event] { load(file) }
}

@main enum StatsProbe {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repetitions = Int(CommandLine.arguments[2])!
        var rows: [[String: Any]] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        for name in ["valid", "damaged"] {
            var times: [Double] = [], events: [Stats.Event] = []
            for _ in 0..<repetitions {
                let start = ContinuousClock.now
                events = Stats.probeLoad(root.appendingPathComponent(name + ".jsonl"))
                times.append(start.duration(to: .now) / .milliseconds(1))
            }
            let sorted = times.sorted(), middle = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            let fingerprint = SHA256.hash(data: try encoder.encode(events)).map { String(format: "%02x", $0) }.joined()
            rows.append(["workload": name, "count": events.count, "events_sha256": fingerprint,
                         "n": repetitions, "median_ms": median, "maximum_ms": sorted.last!, "milliseconds": times])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
    }
}
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(args, log):
    result = subprocess.run(args, cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
    log.write_text(result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="Local git revision containing the original Stats loader")
    parser.add_argument(
        "--out", required=True, type=Path, help="New directory outside the checkout; retained as evidence"
    )
    parser.add_argument("--events", type=int, choices=(1000, 10000), default=10000)
    parser.add_argument("--repetitions", type=int, choices=range(1, 21), default=6)
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists() or ROOT == out or ROOT in out.parents:
        parser.error("--out must be new and outside the checkout")
    out.mkdir(mode=0o700)
    baseline = subprocess.check_output(["git", "show", f"{args.baseline}:{SOURCE}"], cwd=ROOT)
    candidate = (ROOT / SOURCE).read_bytes()
    commit = subprocess.check_output(["git", "rev-parse", args.baseline], cwd=ROOT, text=True).strip()
    protected = str(Path.home() / "Library/Application Support/oops")
    guard = f"(version 1) (allow default) (deny network*) (deny file-read* (subpath {json.dumps(protected)})) (deny file-write* (subpath {json.dumps(protected)}))"
    profile = out / "guard.sb"
    profile.write_text(guard + "\n")
    data = bytearray()
    start = datetime(2023, 11, 14, tzinfo=timezone.utc)
    outcomes = ("fixed", "clear", "failed", "reverted", "reapplied")
    for index in range(args.events):
        event = {
            "date": (start + timedelta(seconds=index * 67)).isoformat().replace("+00:00", "Z"),
            "outcome": outcomes[index % len(outcomes)],
            "words": index % 140,
            "fixes": index % 9,
            "seconds": (index % 100) / 10,
            "model": f"Synthetic-{index % 7}",
            "app": "Synthetic é 👋",
        }
        data.extend(json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode() + b"\n")
    (out / "valid.jsonl").write_bytes(data)
    lines = data.splitlines(keepends=True)
    lines.insert(len(lines) // 2, b"invalid-json\n")
    (out / "damaged.jsonl").write_bytes(b"".join(lines))
    result = {
        "scope": "optimized standalone synchronous load; synthetic files; warm filesystem; no app/UI/hitch acceptance",
        "events": args.events,
        "baseline_commit": commit,
        "runs": {},
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "guard_sha256": digest(profile.read_bytes()),
    }
    for name, source in (("baseline", baseline), ("candidate", candidate)):
        swift = out / f"{name}.swift"
        swift.write_bytes(source + b"\n" + MAIN.encode())
        binary = out / name
        # Macro servers inherit our outer restrictions; macOS cannot apply a nested sandbox.
        compile_args = [
            "/usr/bin/sandbox-exec",
            "-f",
            str(profile),
            "xcrun",
            "swiftc",
            "-disable-sandbox",
            "-O",
            "-swift-version",
            "6",
            "-target",
            "arm64-apple-macosx26.0",
            "-parse-as-library",
            str(swift),
            "-o",
            str(binary),
        ]
        command(compile_args, out / f"{name}-compile.log")
        run_args = ["/usr/bin/sandbox-exec", "-f", str(profile), str(binary), str(out), str(args.repetitions)]
        rows = json.loads(command(run_args, out / f"{name}-run.log"))
        if any(row["count"] != args.events for row in rows):
            raise ValueError("Synthetic event count changed")
        result["runs"][name] = {
            "source_sha256": digest(source),
            "probe_sha256": digest(swift.read_bytes()),
            "binary_sha256": digest(binary.read_bytes()),
            "compile_command": compile_args,
            "compile_command_sha256": digest(json.dumps(compile_args, separators=(",", ":")).encode()),
            "run_command": run_args,
            "run_command_sha256": digest(json.dumps(run_args, separators=(",", ":")).encode()),
            "rows": rows,
        }
    for original, changed in zip(result["runs"]["baseline"]["rows"], result["runs"]["candidate"]["rows"], strict=True):
        if original["events_sha256"] != changed["events_sha256"]:
            raise ValueError("Decoded synthetic events changed")
    result["finished_utc"] = datetime.now(timezone.utc).isoformat()
    (out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
