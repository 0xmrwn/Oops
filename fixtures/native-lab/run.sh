#!/bin/bash
# Records the capsule placement preview in every native-lab scenario: WebKit (the composer-lab
# page in a WKWebView, Mail's engine), AppKit and SwiftUI editors, in a separate fixture app.
# Usage: fixtures/native-lab/run.sh <output-dir> [scenario ...]   (oops must be running and trusted)
# Captures only the fixture's and oops's windows. Leaves no debug default behind.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/fixtures/native-lab"
OUT="${1:?output directory}"
shift
mkdir -p "$OUT"
TOOLS="$ROOT/.build/lab-tools"
mkdir -p "$TOOLS"
for tool in screc trigger activate; do
  [[ "$TOOLS/$tool" -nt "$ROOT/fixtures/composer-lab/tools/$tool.swift" ]] || swiftc -O -o "$TOOLS/$tool" "$ROOT/fixtures/composer-lab/tools/$tool.swift"
done
APP="$TOOLS/NativeLab.app"
if [[ ! "$APP/Contents/MacOS/NativeLab" -nt "$HERE/NativeLab.swift" ]]; then
  mkdir -p "$APP/Contents/MacOS"
  swiftc -O -o "$APP/Contents/MacOS/NativeLab" "$HERE/NativeLab.swift"
  cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NativeLab</string>
<key>CFBundleIdentifier</key><string>dev.0xmrwn.oops-native-lab</string>
<key>CFBundleName</key><string>oops native lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  codesign --force --sign - "$APP" >/dev/null
fi
SCENARIOS="${*:-webkit-chat webkit-chat-textarea webkit-chat-tall webkit-top webkit-document webkit-document-textarea webkit-inline webkit-side webkit-modal appkit-document appkit-middle appkit-selection appkit-scrolled appkit-rtl appkit-large appkit-chat appkit-field appkit-search swiftui-editor swiftui-field}"
CONTROL="$(mktemp "${TMPDIR:-/private/tmp}/oops-native-lab.XXXXXX")"
cleanup() {
  set +e # Best effort, every step: a failure here must not skip restoring oops.
  pkill -f "NativeLab.app/Contents/MacOS/NativeLab"
  rm -f "$CONTROL"
  defaults delete dev.0xmrwn.oops DiagnosticsRemoteTrigger 2>/dev/null || true
  # The trigger observer lives until relaunch; leave oops running without it.
  pkill -x oops || true
  sleep 1
  open "$HOME/Library/Application Support/oops/Development/oops.app" || true
}
trap cleanup EXIT
defaults write dev.0xmrwn.oops DiagnosticsRemoteTrigger -bool true
pkill -x oops || true
sleep 1
open "$HOME/Library/Application Support/oops/Development/oops.app"
sleep 2
echo '{"scenario":"appkit-document","nonce":"start"}' >"$CONTROL"
open -n "$APP" --args "$CONTROL" "$ROOT/fixtures/composer-lab/index.html"
sleep 3
"$TOOLS/activate" "NativeLab.app/Contents/MacOS/NativeLab" >/dev/null
sleep 1
COUNT=$(wc -w <<<"$SCENARIOS")
"$TOOLS/screc" "$OUT/native-run.mov" $((COUNT * 6 + 4)) 165 25 1140 880 dev.0xmrwn.oops-native-lab >"$OUT/screc.log" 2>&1 &
RECORDER=$!
sleep 2
i=0
for scenario in $SCENARIOS; do
  i=$((i + 1))
  echo "{\"scenario\":\"$scenario\",\"nonce\":\"$i\"}" >"$CONTROL"
  # Re-front the fixture: another app coming forward would get the preview instead.
  sleep 1.3
  "$TOOLS/activate" "NativeLab.app/Contents/MacOS/NativeLab" >/dev/null
  sleep 0.2
  "$TOOLS/trigger"
  sleep 4.7
done
wait "$RECORDER"
i=0
for scenario in $SCENARIOS; do
  ffmpeg -loglevel error -y -ss "$(python3 -c "print(4.6 + 6 * $i)")" -i "$OUT/native-run.mov" -frames:v 1 "$OUT/$(printf %02d $((i + 1)))-$scenario.png"
  i=$((i + 1))
done
echo "Recorded $COUNT scenarios to $OUT; placement records are in ~/Library/Application Support/oops/Diagnostics/placement.jsonl"
