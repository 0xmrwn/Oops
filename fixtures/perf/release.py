#!/usr/bin/env python3
"""Plan or collect external Release evidence. Never builds, launches, stops or types into Oops."""

import argparse
import ctypes
import json
import os
import platform
import resource
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from evidence import (
    CONDITIONS,
    CONTEXT_FIELDS,
    METRICS,
    SAMPLE_FIELDS,
    digest,
    read_json,
    summarize,
    timings,
    validate_context,
)

ROOT = Path(__file__).resolve().parents[2]
TRACE_TEMPLATES = {"time-profile": "Time Profiler", "animation": "Animation Hitches"}
MODES = ("idle-rss", "sample-stacks", *TRACE_TEMPLATES)
STACK_INTERVAL_MS = 10
STACK_MAX_SECONDS = 10
STACK_FILE_BYTES = 8 * 1024**2


def command(args, timeout=60):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=timeout).stdout.strip()


def verify_artifact(artifact, source_checkout=ROOT):
    """Use the owning packaging gate, including resources, signatures, hashes and Debug exclusion."""
    metadata = read_json(artifact / "build-info.json")
    if metadata.get("configuration") != "release" or metadata.get("source_dirty") is not False:
        raise ValueError("requires a clean-source Release artifact with build-info.json")
    try:
        command(
            [sys.executable, str(source_checkout / "script/release.py"), "verify", "--artifact", str(artifact)],
            timeout=120,
        )
    except subprocess.CalledProcessError as error:
        raise ValueError(
            "Release verification failed; run script/release.py verify --artifact PATH "
            "from the artifact's source checkout for details"
        ) from error
    return metadata


def identity(pid, binary):
    """Resolve a PID without reading its arguments or selecting a process by name."""
    if sys.platform != "darwin" or pid <= 1 or pid == os.getpid():
        raise ValueError("requires an explicit live Oops PID on macOS")
    proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc.proc_pidpath.restype = ctypes.c_int
    buf = ctypes.create_string_buffer(4096)
    if proc.proc_pidpath(pid, buf, len(buf)) <= 0:
        raise ValueError("cannot resolve PID executable; check PID and permissions")
    actual = Path(os.fsdecode(buf.value)).resolve()
    if actual != binary.resolve():
        raise ValueError("PID executable does not match the verified artifact; refusing attachment")
    started = command(["/bin/ps", "-p", str(pid), "-o", "lstart="])
    if not started:
        raise ValueError("target exited before collection")
    return {"pid": pid, "executable": str(actual), "started": started, "sha256": digest(actual)}


def trace_command(args):
    return [
        "xcrun",
        "xctrace",
        "record",
        "--template",
        TRACE_TEMPLATES[args.mode],
        "--attach",
        str(args.pid),
        "--time-limit",
        f"{args.seconds}s",
        "--output",
        str(args.out / "capture.trace"),
        "--no-prompt",
    ]


def stack_command(args):
    return [
        "/usr/bin/sample",
        str(args.pid),
        str(args.seconds),
        str(STACK_INTERVAL_MS),
        "-file",
        str(args.out / "stacks.txt"),
    ]


def limit_stack_file_size():
    # This CLI is single-threaded. The child inherits a per-file cap before exec.
    _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    cap = STACK_FILE_BYTES if hard == resource.RLIM_INFINITY else min(STACK_FILE_BYTES, hard)
    resource.setrlimit(resource.RLIMIT_FSIZE, (cap, cap))


def collect_stacks(args):
    with (args.out / "profiler.log").open("x") as log:
        subprocess.run(
            stack_command(args),
            stdout=log,
            stderr=log,
            timeout=args.seconds + 10,
            check=True,
            preexec_fn=limit_stack_file_size,
        )
    report = args.out / "stacks.txt"
    if not report.is_file() or not 0 < report.stat().st_size < STACK_FILE_BYTES:
        raise ValueError("stack report missing or at its file cap; collection remains incomplete")
    if not any(line.startswith(b"Call graph:") for line in report.read_bytes().splitlines()):
        raise ValueError("stack report has no call graph; collection remains incomplete")


def plan(args):
    validate_context(read_json(args.context))
    if not 1 <= args.seconds <= 60 or args.pid <= 1:
        raise ValueError("seconds must be 1–60 and pid must be greater than 1")
    if args.mode == "sample-stacks":
        if args.seconds > STACK_MAX_SECONDS:
            raise ValueError("sample-stacks requires 1–10 seconds")
        capture = stack_command(args)
    elif args.mode in TRACE_TEMPLATES:
        capture = trace_command(args)
    else:
        capture = ["/bin/ps", "-p", str(args.pid), "-o", "rss="]
    return {
        "status": "planned-not-verified",
        "artifact": str(args.artifact),
        "source_checkout": str(args.source_checkout),
        "out": str(args.out),
        "mode": args.mode,
        "seconds": args.seconds,
        "pid": args.pid,
        "commands": [capture],
        "effects": "attach/sample the explicit PID only; no app launch, restart, input or cleanup",
        "requires": "verified Release artifact, matching PID and an authorized screen session",
    }


def write_json(path, value):
    # The parent is a freshly reserved run directory; refuse replacement even within it.
    with path.open("x") as stream:
        stream.write(json.dumps(value, indent=2, allow_nan=False) + "\n")


def collect(args):
    preview = plan(args)
    if args.dry_run:
        return preview
    if not args.session_ready:
        raise ValueError("record requires --session-ready after an authorized screen session is available")
    context = validate_context(read_json(args.context))
    if any(isinstance(value, str) and value.startswith("EXAMPLE ONLY:") for value in context.values()):
        raise ValueError("replace example context values with observed session metadata before recording")
    artifact = args.artifact.resolve()
    if args.out.exists() or args.out.is_symlink():
        raise ValueError("output exists; choose a new run directory (nothing will be overwritten)")
    if args.mode in TRACE_TEMPLATES and shutil.disk_usage(args.out.parent).free < 30 * 1024**3:
        raise ValueError("tracing requires at least 30 GiB free; no automatic cleanup is performed")
    if args.mode == "sample-stacks" and shutil.disk_usage(args.out.parent).free < 64 * 1024**2:
        raise ValueError("sample-stacks requires at least 64 MiB free for its capped text files")
    source_checkout = args.source_checkout.resolve()
    metadata = verify_artifact(artifact, source_checkout)
    binary = artifact / "Oops.app/Contents/MacOS/oops"
    before = identity(args.pid, binary)
    args.out.mkdir(mode=0o700)  # Exclusive reservation: parallel runs cannot share an output.
    manifest = {
        "schema_version": 1,
        "status": "incomplete",
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "artifact": str(artifact),
        "build_info_sha256": digest(artifact / "build-info.json"),
        "build": metadata,
        "source_checkout": str(source_checkout),
        "collector_revision": command(["git", "-C", str(ROOT), "rev-parse", "HEAD"]),
        "collector_dirty": bool(command(["git", "-C", str(ROOT), "status", "--porcelain"])),
        "collector_sha256": {p.name: digest(p) for p in (Path(__file__), ROOT / "fixtures/perf/evidence.py")},
        "target": before,
        "context": context,
        "profiler": {
            "template": TRACE_TEMPLATES.get(args.mode),
            "xcode": command(["xcodebuild", "-version"]),
            "xctrace_path": command(["xcrun", "--find", "xctrace"]) if args.mode in TRACE_TEMPLATES else None,
        },
        "machine": {
            "model": command(["/usr/sbin/sysctl", "-n", "hw.model"]),
            "chip": command(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]),
            "memory_bytes": int(command(["/usr/sbin/sysctl", "-n", "hw.memsize"])),
            "architecture": platform.machine(),
            "os": command(["/usr/bin/sw_vers"]),
        },
        "mode": args.mode,
        "requested_seconds": args.seconds,
        "sampling": {
            "idle-rss": "RSS every 1 second (KiB / 1024); correlated points within one run",
            "sample-stacks": f"wall-clock thread stacks, {STACK_INTERVAL_MS} ms interval; includes waiting stacks",
        }.get(args.mode, "external trace; no automatic latency or frame derivation"),
    }
    if args.mode == "sample-stacks":
        manifest["profiler"].update(command=stack_command(args), file_limit_bytes=STACK_FILE_BYTES)
    write_json(args.out / "manifest.json", manifest)
    try:
        began = time.monotonic()
        if args.mode == "idle-rss":
            samples = []
            with (args.out / "samples.jsonl").open("x") as stream:
                for _ in range(args.seconds):
                    if identity(args.pid, binary) != before:
                        raise ValueError("target identity changed during sampling")
                    rss = int(command(["/bin/ps", "-p", str(args.pid), "-o", "rss="]))
                    sample = {
                        "metric": "idle_rss_mib",
                        "value": rss / 1024,
                        "case": manifest["context"]["workload"],
                        "condition": manifest["context"]["condition"],
                        "outcome": "observed",
                        "source": "ps-rss-1s",
                    }
                    stream.write(json.dumps(sample) + "\n")
                    samples.append({"elapsed_s": time.monotonic() - began, "rss_kib": rss})
                    time.sleep(1)
            write_json(args.out / "rss-observations.json", samples)
        elif args.mode == "sample-stacks":
            collect_stacks(args)
        else:
            with (args.out / "profiler.log").open("x") as log:
                subprocess.run(trace_command(args), stdout=log, stderr=log, check=True, timeout=args.seconds + 30)
            trace = args.out / "capture.trace"
            if not trace.is_dir() or not any(trace.iterdir()):
                raise ValueError("profiler returned without a nonempty trace; collection remains incomplete")
        if identity(args.pid, binary) != before:
            raise ValueError("target identity changed during collection")
        # Detect changed artifact inputs as well as a replaced target executable.
        if verify_artifact(artifact, source_checkout) != metadata:
            raise ValueError("artifact metadata changed during collection")
        write_json(args.out / "result.json", {"status": "collected", "elapsed_s": time.monotonic() - began})
    except (Exception, KeyboardInterrupt):
        # Keep the manifest and any partial trace. Absence of result.json means incomplete.
        raise
    return {"status": "collected", "out": str(args.out), "manifest": str(args.out / "manifest.json")}


def parser():
    result = argparse.ArgumentParser(
        description=__doc__, epilog="JSON stdout. Exit: 0 success, 1 refusal/failure, 2 usage."
    )
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser("schema", help="Describe context and reviewed-sample fields")
    verify = sub.add_parser("verify", help="Verify a Release artifact offline; never signs or launches")
    verify.add_argument("--artifact", type=Path, required=True)
    source_help = "Trusted checkout whose packaging verifier matches the build inputs (default: collector checkout)"
    verify.add_argument("--source-checkout", type=Path, default=ROOT, help=source_help)
    for name in ("plan", "record"):
        cmd = sub.add_parser(
            name,
            help="Preview collection" if name == "plan" else "Collect from an explicit verified PID",
            epilog=f"Example: release.py {name} --artifact dist/release/oops-0.1.0-9 "
            "--context context.json --pid 12345 --out .build/perf/run-01 --mode idle-rss",
        )
        cmd.add_argument("--artifact", type=Path, required=True)
        cmd.add_argument("--source-checkout", type=Path, default=ROOT, help=source_help)
        cmd.add_argument("--context", type=Path, required=True, help="Synthetic workload and observed session metadata")
        cmd.add_argument("--pid", type=int, required=True)
        cmd.add_argument("--out", type=Path, required=True, help="New directory; parent must exist")
        cmd.add_argument("--mode", choices=MODES, default="idle-rss")
        cmd.add_argument("--seconds", type=int, default=30, help="1–60 (default 30); 1–10 for sample-stacks")
        if name == "record":
            cmd.add_argument("--session-ready", action="store_true", help="Assert the authorized session is available")
            cmd.add_argument("--dry-run", action="store_true", help="Plan only; no verification, PID access or writes")
    summary = sub.add_parser("summarize", help="Summarize reviewed JSONL samples; never assesses acceptance")
    summary.add_argument("--samples", type=Path, required=True)
    extract = sub.add_parser(
        "timings", help="Extract capture/apply scalars for explicitly selected diagnostic attempts"
    )
    extract.add_argument("--log", type=Path, required=True, help="Private diagnostic JSONL; never copied")
    extract.add_argument(
        "--selection", type=Path, required=True, help="JSON mapping attempt UUID to case and condition"
    )
    return result


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    if arguments[:1] == ["help"]:
        arguments = arguments[1:] + ["--help"]
    args = parser().parse_args(arguments)
    try:
        if args.command == "schema":
            data = {
                "schema_version": 1,
                "context_fields": sorted(CONTEXT_FIELDS),
                "sample_fields": sorted(SAMPLE_FIELDS),
                "metrics": METRICS,
                "conditions": CONDITIONS,
                "sample_value": "finite nonnegative number, or null when missing",
                "format": "JSON; samples JSONL",
            }
        elif args.command == "verify":
            data = {
                "status": "verified-artifact",
                "build": verify_artifact(args.artifact.resolve(), args.source_checkout.resolve()),
            }
        elif args.command == "plan":
            data = plan(args)
        elif args.command == "record":
            data = collect(args)
        elif args.command == "timings":
            data = timings(args.log, args.selection)
        else:
            data = summarize(args.samples)
        print(json.dumps({"ok": True, "data": data}, allow_nan=False))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError) as error:
        # Raw profiler/verification output stays local; never echo log contents or command arguments.
        message = (
            str(error) if isinstance(error, ValueError) else f"{type(error).__name__}; check inputs and local tool logs"
        )
        print(json.dumps({"ok": False, "error": {"code": "COLLECTION_FAILED", "message": message}}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
