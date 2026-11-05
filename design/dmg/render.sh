#!/bin/bash
# Regenerates the DMG window: the background (1x, 2x and the HiDPI background.tiff), its Finder previews,
# and DS_Store, the Finder layout the release copies onto the disk image. Opens no window: dmgbuild and
# the copy below attach their throwaway image with -nobrowse. Needs uv for dmgbuild.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$PROJECT_ROOT/design/dmg"
ICON_TOOL="${OOPS_ICON_COMPOSER_TOOL:-$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool}"
if [[ ! -x "$ICON_TOOL" ]]; then
  echo "Missing Xcode Icon Composer. Set OOPS_ICON_COMPOSER_TOOL to its ictool executable." >&2
  exit 1
fi
WORK="$(mktemp -d)"
trap 'hdiutil detach -quiet "$WORK/mount" 2>/dev/null || true; rm -rf "$WORK"' EXIT
# Finder shows the Default icon in light appearance and the Dark one in dark, at 128 points.
for appearance in Default Dark; do
  "$ICON_TOOL" "$PROJECT_ROOT/Resources/Oops.icon" --export-image --output-file "$WORK/icon-$appearance.png" \
    --platform macOS --rendition "$appearance" --width 128 --height 128 --scale 2 >/dev/null
done
cd "$PROJECT_ROOT"
swift design/dmg/backgrounds.swift
swift design/dmg/preview.swift "$WORK"
tiffutil -cathidpicheck "$HERE/background.png" "$HERE/background@2x.png" -out "$HERE/background.tiff" >/dev/null 2>&1
uv run --quiet --no-project --with dmgbuild==1.6.7 dmgbuild -s "$HERE/layout.py" \
  -D background="$HERE/background.tiff" Oops "$WORK/layout.dmg" >/dev/null
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/mount" "$WORK/layout.dmg"
cp "$WORK/mount/.DS_Store" "$HERE/DS_Store"
echo "Wrote background.tiff and DS_Store"
