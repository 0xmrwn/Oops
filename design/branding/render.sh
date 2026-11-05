#!/bin/bash
# Native generation/appearance proofs; also refreshes the two bundled in-window previews.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -ne 1 || "$1" == "--help" ]]; then
  echo "usage: $0 <proof-output-directory>" >&2
  echo "Exports both generations and all six appearances; refreshes Resources/OopsIcon*.png." >&2
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 2
fi
OUTPUT_DIR="$1"
ICON_TOOL="${OOPS_ICON_COMPOSER_TOOL:-$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool}"
if [[ ! -x "$ICON_TOOL" ]]; then
  echo "Missing Xcode Icon Composer. Set OOPS_ICON_COMPOSER_TOOL to its ictool executable." >&2
  exit 1
fi
ICON_HELP="$("$ICON_TOOL" --help)"
if [[ "$ICON_HELP" != *--design-generation* ]]; then
  echo "This ictool cannot compare generations. Use the Xcode 27 tool, not standalone Icon Composer 2." >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
"$ICON_TOOL" --version >"$OUTPUT_DIR/tool-version.json"
shasum -a 256 "$PROJECT_ROOT/Resources/Oops.icon/icon.json" "$PROJECT_ROOT/Resources/Oops.icon/Assets/"*.svg >"$OUTPUT_DIR/source.sha256"
for generation in 26 27; do
  for appearance in Default Dark ClearLight ClearDark TintedLight TintedDark; do
    for size in 16 32 64 128; do
      for scale in 1 2; do
        "$ICON_TOOL" "$PROJECT_ROOT/Resources/Oops.icon" --export-image \
          --output-file "$OUTPUT_DIR/$generation-$appearance-$size@${scale}x.png" \
          --platform macOS --rendition "$appearance" --width "$size" --height "$size" \
          --scale "$scale" --design-generation "$generation" >/dev/null
      done
    done
  done
done
for appearance in Default Dark; do
  preview="OopsIcon.png"
  if [[ "$appearance" == Dark ]]; then preview="OopsIcon-dark.png"; fi
  "$ICON_TOOL" "$PROJECT_ROOT/Resources/Oops.icon" --export-image \
    --output-file "$PROJECT_ROOT/Resources/$preview" --platform macOS --rendition "$appearance" \
    --width 1024 --height 1024 --scale 1 --design-generation 27 >/dev/null
done
echo "Exported 96 native proofs and refreshed Default/Dark previews."
