#!/bin/bash
# Measures frame pacing of one oops surface without taking focus, and without big files.
# Usage: fixtures/perf/run.sh <settings|capsule|editor> <out-dir> [seconds] [light|dark]
# oops runs with launch-only arguments (never persisted): -PerfHarness loops the surface with its
# windows ordered front but oops never activated; FramePacer records each display-link frame and
# writes <out-dir>/<surface>-<appearance>.json (a few KB); oops then quits and is relaunched.
# INSTRUMENTS=1 adds one short Instruments trace (TEMPLATE, default Time Profiler) for a deep dive: refused below 30 GB free,
# and its raw ktrace in $TMPDIR (gigabytes, never cleaned by xctrace) is deleted afterwards.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SURFACE="${1:?surface}"
OUT="${2:?output directory}"
SECONDS_="${3:-10}"
APPEARANCE="${4:-dark}"
APP="$HOME/Library/Application Support/oops/Development/oops.app"
REPORT="$OUT/$SURFACE-$APPEARANCE.json"
mkdir -p "$OUT"
rm -f "$REPORT"
free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }
restore() {
  pkill -x oops || true
  sleep 1
  open "$APP" || true
}
trap restore EXIT
pkill -x oops || true
for _ in $(seq 1 50); do
  pgrep -x oops >/dev/null || break
  sleep 0.1
done # Never measure a quitting copy.
# shellcheck disable=SC2086 # EXTRA_ARGS is a list of arguments, split on purpose.
open -n "$APP" --args -PerfHarness "$SURFACE" -PerfReport "$REPORT" -PerfSeconds "$SECONDS_" \
  -SettingsPreviewAppearance "$APPEARANCE" -CapsuleAppearance "$APPEARANCE" ${EXTRA_ARGS:-}
if [[ -n "${INSTRUMENTS:-}" ]]; then
  (($(free_gb) >= 30)) || {
    echo "Refusing Instruments: under 30 GB free." >&2
    exit 1
  }
  MARK="$(mktemp)"
  TRACE="$OUT/$SURFACE-$APPEARANCE.trace"
  rm -rf "$TRACE"
  sleep 1.5
  # TEMPLATE='Time Profiler' samples only oops; Animation Hitches traces the whole system.
  xcrun xctrace record --template "${TEMPLATE:-Time Profiler}" --attach "$(pgrep -n -x oops)" \
    --time-limit "$(python3 -c "print(min($SECONDS_, 6))")s" --output "$TRACE" >"$OUT/$SURFACE-$APPEARANCE.log" 2>&1 || true
  python3 "$ROOT/fixtures/perf/report.py" "$TRACE" || true
  [[ -n "${KEEP:-}" ]] || rm -rf "$TRACE" # KEEP=1 keeps the .trace (tens of MB for Time Profiler).
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'instruments*.ktrace' -newer "$MARK" -delete
  rm -f "$MARK"
fi
for _ in $(seq 1 $(((SECONDS_ + 15) * 10))); do
  [[ -s "$REPORT" ]] && ! pgrep -x oops >/dev/null && break
  sleep 0.1
done
python3 - "$REPORT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"{r['frames']} frames at {r['refreshHz']:.0f} Hz over {r['seconds']:.1f} s: {r['missedFrames']} missed, "
      f"worst {r['worstMs']:.0f} ms, p99 {r['p99Ms']:.1f} ms, CPU {r['cpuPercent']:.1f}%")
if r.get("reactionMs"):
    react = r["reactionMs"]
    print(f"  click to next frame: mean {sum(react) / len(react):.0f} ms, worst {max(react):.0f} ms ({', '.join(f'{v:.0f}' for v in react)})")
if r.get("marks"):
    # Where late frames fall after the most recent change: 0-50 ms is the click itself.
    buckets = {}
    for l in r["late"]:
        before = [m for m in r["marks"] if m <= l["at"]]
        if not before: continue
        since = (l["at"] - before[-1]) * 1000
        key = "0-50" if since < 50 else "50-200" if since < 200 else "200-450" if since < 450 else "450+"
        buckets[key] = buckets.get(key, 0) + max(round(l["ms"] / (1000 / r["refreshHz"])) - 1, 0)
    print("  missed frames by time after the change (ms):", ", ".join(f"{k}: {buckets.get(k, 0)}" for k in ("0-50", "50-200", "200-450", "450+")))
if r["late"]: print("  late frames:", ", ".join(f"{l['at']:.2f}s/{l['ms']:.0f}ms" for l in r["late"][:40]))
PY
echo "free disk: $(free_gb) GB"
