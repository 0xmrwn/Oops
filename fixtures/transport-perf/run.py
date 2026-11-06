#!/usr/bin/env python3
"""Build and collect a Release XCTest loopback transport pilot."""

import argparse
import hashlib
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from threading import Thread

from fixture import FixtureServer
from report import read_samples, sample_schema, summarize
from tls import OPENSSL, fixture_tls

ROOT = Path(__file__).resolve().parents[2]
PROBE = "OopsCoreTests.TransportPerfProbe/testLoopbackPairs"
SWIFT_OVERLAY = Path(__file__).with_name("swift-overlay.patch")
PROBE_SWIFT_INPUTS = {
    "Sources/OopsCore/Providers/OpenAICompatible.swift": "db61c3980ef799079bb0458697ac9e4aad1ced58443cfb9e4f08f5dd84733f6e",
    "Tests/OopsCoreTests/TransportPerfProbe.swift": "0abcfd7459e3a6e599d0312ccdd78326ee176c06c6d5564f09bb69ddebb303d3",
}
META = {"tool": "oops-transport-perf", "version": "1.0", "schema_version": "1.0"}
NO_NETWORK = "(version 1) (allow default) (deny network*)"
LOOPBACK_ONLY = (
    '(version 1) (allow default) (deny network-outbound) (allow network-outbound (remote ip "localhost:{port}"))'
)
SANDBOX = "/usr/bin/sandbox-exec"


class PilotError(Exception):
    def __init__(self, code, message, status=1):
        super().__init__(message)
        self.code = code
        self.status = status


def commands(swift):
    base = [
        SANDBOX,
        "-p",
        NO_NETWORK,
        swift,
        "build",
        "--configuration",
        "release",
        "--disable-sandbox",
        "--disable-keychain",
        "--disable-automatic-resolution",
    ]
    # The package's existing test targets import internal symbols even in Release configuration.
    build = [*base, "--build-tests", "--jobs", "4", "-Xswiftc", "-enable-testing"]
    return build, [*base, "--show-bin-path"]


def environment():
    env = {
        key: os.environ[key]
        for key in ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "LANG")
        if key in os.environ
    }
    env["CLANG_MODULE_CACHE_PATH"] = str(ROOT / ".build" / "clang-cache")
    env["OOPS_LIVE_CLAUDE"] = "0"
    return env


def capture(command, env):
    try:
        return subprocess.run(
            command,
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=True,
            timeout=20,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise PilotError("ENVIRONMENT", f"Could not query {Path(command[0]).name}.", 3) from error


def source_identity(env):
    if capture(["git", "status", "--porcelain"], env):
        raise PilotError("DIRTY_SOURCE", "Run from a clean, committed fixture checkout.")
    return {
        "commit": capture(["git", "rev-parse", "HEAD"], env),
        "tree": capture(["git", "rev-parse", "HEAD^{tree}"], env),
        "dirty": False,
    }


def require_local_dependencies():
    cached = (
        ".build/workspace-state.json",
        ".build/checkouts/Sparkle/Package.swift",
        ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/Info.plist",
    )
    if not all((ROOT / path).is_file() for path in cached):
        raise PilotError(
            "MISSING_CACHE", "Prepare the pinned SwiftPM checkout and binary artifact cache locally first.", 3
        )


def require_swift_overlay():
    for relative, expected in PROBE_SWIFT_INPUTS.items():
        source = ROOT / relative
        if not source.is_file() or digest(source) != expected:
            raise PilotError(
                "SWIFT_OVERLAY_REQUIRED",
                "Apply and commit fixtures/transport-perf/swift-overlay.patch in an isolated checkout. See README.md.",
                3,
            )


def run_child(command, env, timeout, log):
    with log.open("xb") as sink:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=sink,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=3)
                except ProcessLookupError:
                    process.wait()
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def command_digest(command):
    return hashlib.sha256(json.dumps(command, separators=(",", ":")).encode("utf-8")).hexdigest()


def verify_executable(path, expected):
    try:
        actual = digest(path)
    except OSError as error:
        raise PilotError("BINARY_CHANGED", "The Release test executable is unavailable.", 4) from error
    if actual != expected:
        raise PilotError("BINARY_CHANGED", "The Release test executable digest changed.", 4)
    return actual


def write_json(path, value):
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")
    temp.replace(path)


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def collect(args):
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        raise PilotError("OUTPUT_INSIDE_SOURCE", "Choose a new output directory outside this checkout.")
    if out.exists() or not out.parent.is_dir():
        raise PilotError("OUTPUT_PATH", "Output must be a new directory under an existing parent.")
    env = environment()
    swift = shutil.which("swift", path=env.get("PATH"))
    if not swift:
        raise PilotError("ENVIRONMENT", "Swift is unavailable.", 3)
    build, bin_query = commands(swift)
    if args.dry_run:
        return {
            "out": str(out),
            "pairs": args.pairs,
            "timeoutPerCommandSeconds": args.timeout,
            "buildCommand": build,
            "probeSelector": PROBE,
            "scheme": args.scheme,
            "session": args.session,
            "closeAfterFirst": args.close_after_first,
            "fixture": "127.0.0.1 with an ephemeral port",
            "swiftOverlay": "Apply and commit swift-overlay.patch in an isolated checkout before collecting.",
        }

    require_swift_overlay()
    require_local_dependencies()
    source = source_identity(env)
    xctest = capture(["xcrun", "--find", "xctest"], env)
    out.mkdir(mode=0o700)
    manifest = {
        "schemaVersion": META["schema_version"],
        "source": source,
        "packageResolvedSha256": digest(ROOT / "Package.resolved"),
        "probeSourceSha256": digest(ROOT / "Tests/OopsCoreTests/TransportPerfProbe.swift"),
        "instrumentedBackendSha256": digest(ROOT / "Sources/OopsCore/Providers/OpenAICompatible.swift"),
        "swiftOverlaySha256": digest(SWIFT_OVERLAY),
        "fixtureSourceSha256": {
            name: digest(Path(__file__).with_name(name)) for name in ("run.py", "fixture.py", "report.py", "tls.py")
        },
        "swiftVersion": capture([swift, "--version"], env),
        "xcodeVersion": capture(["xcodebuild", "-version"], env),
        "host": {"arch": platform.machine(), "macOS": platform.mac_ver()[0], "kernel": platform.release()},
        "configuration": "release with testability",
        "buildCommand": build,
        "buildCommandSha256": command_digest(build),
        "binaryPathQuery": bin_query,
        "cwd": str(ROOT),
        "startedUTC": utc_now(),
        "pairs": args.pairs,
        "timeoutPerCommandSeconds": args.timeout,
        "session": {
            "configuration": args.session,
            "scope": "per pair" if args.session == "ephemeral" else "one default shared session per probe process",
            "requestsPerPair": 2,
            "resourceTimeoutSeconds": 5 if args.session == "ephemeral" else None,
            "backendRequestTimeoutSeconds": 35,
            "backendDeadlineSeconds": 40,
            "taskMetricsTimeoutSeconds": 2,
            "sessionStorageAndProxy": "disabled" if args.session == "ephemeral" else "default session settings",
            "metrics": "per-task delegate",
            "redirects": False,
        },
        "scheme": args.scheme,
        "closeAfterFirst": args.close_after_first,
        "workload": "synthetic canned JSON, literal IPv4 loopback, HTTP/1.1 keepalive",
    }
    write_json(out / "manifest.json", manifest)
    print("Building the Release test bundle with network disabled.", file=sys.stderr)
    if run_child(build, env, args.timeout, out / "build.log") != 0:
        raise PilotError("BUILD_FAILED", "Release test build failed. See build.log.")
    products = Path(capture(bin_query, env).splitlines()[-1]).resolve()
    bundle = products / "OopsCoreTests.xctest"
    binary = bundle / "Contents" / "MacOS" / "OopsCoreTests"
    if ROOT / ".build" not in products.parents or not binary.is_file():
        raise PilotError("NO_BUNDLE", "The expected local Release test bundle is missing.", 3)
    manifest["testExecutableSha256"] = digest(binary)
    write_json(out / "manifest.json", manifest)
    if source_identity(env) != source:
        raise PilotError("SOURCE_CHANGED", "The checkout changed while building.")

    run_id = str(uuid.uuid4())
    samples = out / "samples.jsonl"
    samples.touch(exist_ok=False)
    config = out / "probe.json"
    tls = None
    if args.scheme == "https":

        def create_certificate(command, log):
            if run_child([SANDBOX, "-p", NO_NETWORK, *command], env, min(args.timeout, 15), log) != 0:
                raise PilotError(
                    "TLS_FIXTURE_FAILED", "Could not generate the temporary fixture certificate. See tls logs."
                )

        tls, provenance = fixture_tls(out, create_certificate)
        manifest["fixtureTLS"] = {**provenance, "opensslVersion": capture([OPENSSL, "version"], env)}
    with FixtureServer(run_id, args.pairs, tls=tls, close_after_first=args.close_after_first) as server:
        profile = LOOPBACK_ONLY.format(port=server.server_port)
        probe = [SANDBOX, "-p", profile, xctest, "-XCTest", PROBE, str(bundle)]
        write_json(
            config,
            {
                "id": run_id,
                "port": server.server_port,
                "pairs": args.pairs,
                "scheme": args.scheme,
                "session": args.session,
            },
        )
        manifest.update(
            {
                "probeCommand": probe,
                "probeCommandSha256": command_digest(probe),
                "probeConfigSha256": digest(config),
                "probeStartedUTC": utc_now(),
            }
        )
        write_json(out / "manifest.json", manifest)
        env["OOPS_TRANSPORT_PERF_CONFIG"] = str(config)
        thread = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        try:
            print(f"Collecting {args.pairs} sequential request pairs from the owned loopback fixture.", file=sys.stderr)
            manifest["testExecutableSha256BeforeProbe"] = verify_executable(binary, manifest["testExecutableSha256"])
            code = run_child(probe, env, args.timeout, out / "probe.log")
        finally:
            try:
                manifest["testExecutableSha256AfterProbe"] = verify_executable(binary, manifest["testExecutableSha256"])
            finally:
                server.shutdown()
                thread.join()
                server_data = server.snapshot()
                write_json(out / "server.json", server_data)
                rows, invalid = read_samples(samples)
                result = summarize(rows, invalid, server_data, args.pairs, scheme=args.scheme)
                write_json(out / "summary.json", result)
                write_json(out / "manifest.json", manifest)
    if source_identity(env) != source:
        raise PilotError("SOURCE_CHANGED", "The checkout changed while measuring.")
    manifest.update({"finishedUTC": utc_now(), "probeExitCode": code})
    write_json(out / "manifest.json", manifest)
    if (
        code
        or result["completePairs"] != args.pairs
        or any(result[key] for key in ("invalidRows", "serverRejected", "serverHandlerErrors", "reuseDisagreements"))
    ):
        raise PilotError("INCOMPLETE", "The pilot is incomplete. See probe.log and summary.json.", 4)
    if args.close_after_first and result["second"]["reportedReused"]:
        raise PilotError("UNEXPECTED_REUSE", "The connection-close control observed reuse. See summary.json.", 4)
    return {"out": str(out), "completePairs": result["completePairs"], "sameSocketPairs": result["sameSocketPairs"]}


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        raise PilotError("USAGE", message, 2)


def bounded(lo, hi):
    def parse(value):
        number = int(value)
        if not lo <= number <= hi:
            raise argparse.ArgumentTypeError(f"expected {lo} through {hi}")
        return number

    return parse


def main(argv=None):
    parser = Arguments(
        description=__doc__, epilog="Example: %(prog)s collect --out /private/tmp/oops-transport-01 --pairs 20"
    )
    commands_parser = parser.add_subparsers(dest="command", required=True)
    measure = commands_parser.add_parser("collect", help="Build and measure only the loopback test")
    measure.add_argument("--out", type=Path, required=True, help="New output directory outside the checkout")
    measure.add_argument("--pairs", type=bounded(1, 100), default=20, help="Sequential pairs (default: 20)")
    measure.add_argument(
        "--scheme", choices=("http", "https"), default="http", help="Fixture transport (default: http)"
    )
    measure.add_argument(
        "--session",
        choices=("ephemeral", "shared"),
        default="ephemeral",
        help="Session selection (default: ephemeral per pair)",
    )
    measure.add_argument(
        "--close-after-first",
        action="store_true",
        help="Close the fixture connection after the first response of each pair",
    )
    measure.add_argument(
        "--timeout", type=bounded(1, 900), default=300, help="Seconds per build or probe (default: 300)"
    )
    measure.add_argument("--dry-run", action="store_true", help="Print the plan without files, processes or sockets")
    commands_parser.add_parser("schema", help="Describe one samples.jsonl row as JSON Schema")
    args = None
    try:
        args = parser.parse_args(argv)
        data = sample_schema() if args.command == "schema" else collect(args)
        print(json.dumps({"ok": True, "data": data, "meta": META}, allow_nan=False))
        return 0
    except subprocess.TimeoutExpired:
        error = PilotError("TIMEOUT", "An owned command timed out. See the run logs.", 11)
    except KeyboardInterrupt:
        error = PilotError("INTERRUPTED", "The pilot was interrupted.", 130)
    except PilotError as failure:
        error = failure
    except OSError:
        error = PilotError("LOCAL_IO", "Could not access a local artifact, tool or loopback socket.")
    data = {"out": str(args.out.resolve())} if args is not None and args.command == "collect" else {}
    print(json.dumps({"ok": False, "error": {"code": error.code, "message": str(error)}, "data": data, "meta": META}))
    return error.status


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
