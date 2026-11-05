#!/bin/bash
# Records the capsule placement preview in every composer-lab scenario, in a throwaway Chrome
# (Chromium, like Teams, Claude and Codex) with its own temporary profile.
# Usage: fixtures/composer-lab/run.sh <output-dir>   (oops must be running and trusted for Accessibility)
# Design recordings: PAGE=light|dark A11Y=reduce-motion,reduce-transparency,increase-contrast THEME=light|dark WORKING=<s> OUTCOME=fixed|clear|failed|pending|reverted SCENARIOS="…" CROP="x y w h"
# Captures only Chrome's and oops's windows. Leaves no debug default or Chrome profile behind.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB="$ROOT/fixtures/composer-lab"
OUT="${1:?output directory}"
mkdir -p "$OUT"
TOOLS="$ROOT/.build/lab-tools"
mkdir -p "$TOOLS"
for tool in screc trigger activate; do
  [[ "$TOOLS/$tool" -nt "$LAB/tools/$tool.swift" ]] || swiftc -O -o "$TOOLS/$tool" "$LAB/tools/$tool.swift"
done
PROFILE="$(mktemp -d "${TMPDIR:-/private/tmp}/oops-lab-chrome.XXXXXX")"
SCENARIOS="${SCENARIOS:-chat chat-textarea chat-tall top document document-textarea inline side modal}"
WORKING="${WORKING:-1.7}"
# Each scenario waits until its drop has left: a failure lingers 8 s, a revert follows its fix after 1.4 s.
case "${OUTCOME:-fixed}" in failed) DWELL=8.7 ;; reverted) DWELL=3.6 ;; *) DWELL=2.2 ;; esac
STEP=$(python3 -c "print(round(1.3 + 0.25 + $WORKING + $DWELL, 1))")
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
until_time() { sleep "$(perl -e '$d = $ARGV[0] - $ARGV[1]; printf "%.3f", $d > 0 ? $d : 0' "$1" "$(now)")"; }
CROP="${CROP:-165 25 1140 850}"
PAGE_THEME="${PAGE:-${THEME:-}}" # The page can differ from the capsule appearance.
cleanup() {
  set +e # Best effort, every step: a failure here must not skip restoring oops.
  pkill -f "user-data-dir=$PROFILE"
  for _ in $(seq 1 40); do
    pgrep -f "user-data-dir=$PROFILE" >/dev/null || break
    sleep 0.25
  done
  rm -rf "$PROFILE"
  for key in DiagnosticsRemoteTrigger CapsuleAccessibility CapsuleAppearance PreviewWorkingSeconds PreviewOutcome; do defaults delete dev.0xmrwn.oops "$key" 2>/dev/null || true; done
  # The trigger observer lives until relaunch; leave oops running without it.
  pkill -x oops || true
  sleep 1
  open "$HOME/Library/Application Support/oops/Development/oops.app" || true
  [[ -n "${SERVER:-}" ]] && kill "$SERVER" 2>/dev/null || true
}
trap cleanup EXIT
# The debug trigger is read at launch; relaunch oops with it on.
defaults write dev.0xmrwn.oops DiagnosticsRemoteTrigger -bool true
[[ -n "${PLATE:-}" ]] && defaults write dev.0xmrwn.oops -float "$PLATE"
[[ -n "${A11Y:-}" ]] && defaults write dev.0xmrwn.oops CapsuleAccessibility "$A11Y"
[[ -n "${THEME:-}" ]] && defaults write dev.0xmrwn.oops CapsuleAppearance "$THEME"
defaults write dev.0xmrwn.oops PreviewWorkingSeconds -float "$WORKING"
defaults write dev.0xmrwn.oops PreviewOutcome "${OUTCOME:-fixed}"
pkill -x oops || true
sleep 1
open "$HOME/Library/Application Support/oops/Development/oops.app"
sleep 2
python3 -m http.server 4417 --bind 127.0.0.1 --directory "$LAB" >/dev/null 2>&1 &
SERVER=$!
echo '{"scenario":"chat","nonce":"start"}' >"$LAB/control.json"
sleep 1
open -na "Google Chrome" --args --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check --disable-sync \
  --app="http://127.0.0.1:4417/?follow=1${PAGE_THEME:+&theme=$PAGE_THEME}#chat" --window-size=1100,760 --window-position=185,95
sleep 4
"$TOOLS/activate" "user-data-dir=$PROFILE" >/dev/null
sleep 1
COUNT=$(wc -w <<<"$SCENARIOS")
# shellcheck disable=SC2086 # CROP is four numbers, split on purpose.
"$TOOLS/screc" "$OUT/lab-run.mov" "$(python3 -c "print(int($COUNT * $STEP + 4))")" $CROP com.google.Chrome >"$OUT/screc.log" 2>&1 &
RECORDER=$!
# Video time 0 is when capture starts; scenarios run on a fixed clock from there and stills are
# taken from each trigger's measured time, so tool start-up latency never drifts them.
for _ in $(seq 1 200); do
  grep -q recording "$OUT/screc.log" 2>/dev/null && break
  sleep 0.05
done
START=$(now)
i=0
TRIGGERS=()
for scenario in $SCENARIOS; do
  until_time "$(python3 -c "print($START + 1 + $STEP * $i)")"
  i=$((i + 1))
  echo "{\"scenario\":\"$scenario\",\"nonce\":\"$i\"}" >"$LAB/control.json"
  # Re-front the fixture: another app coming forward would get the preview instead.
  sleep 1.3
  "$TOOLS/activate" "user-data-dir=$PROFILE" >/dev/null
  sleep 0.2
  "$TOOLS/trigger"
  TRIGGERS+=("$(python3 -c "print(round($(now) - $START, 2))")")
done
wait "$RECORDER"
# Two stills per scenario: mid-working, and the outcome once its entrance has settled.
i=0
for scenario in $SCENARIOS; do
  t=${TRIGGERS[$i]}
  i=$((i + 1))
  ffmpeg -loglevel error -y -ss "$(python3 -c "print($t + 0.25 + $WORKING / 2)")" -i "$OUT/lab-run.mov" -frames:v 1 "$OUT/$i-$scenario.png"
  ffmpeg -loglevel error -y -ss "$(python3 -c "print($t + 0.25 + $WORKING + 0.8)")" -i "$OUT/lab-run.mov" -frames:v 1 "$OUT/$i-$scenario-outcome.png"
done
echo "Recorded to $OUT; placement records are in ~/Library/Application Support/oops/Diagnostics/placement.jsonl"
