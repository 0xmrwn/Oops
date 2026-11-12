#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
case "$MODE" in
  run | --build-only | --brand-review | --verify | --debug | --logs | --telemetry) ;;
  *)
    echo "usage: $0 [run|--build-only|--brand-review|--verify|--debug|--logs|--telemetry]" >&2
    exit 2
    ;;
esac
SIGNING_FILE="$HOME/Library/Application Support/oops/Development/signing-identity.txt"
SIGNING_IDENTITY="${OOPS_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f "$SIGNING_FILE" ]]; then
  SIGNING_IDENTITY="$(cat "$SIGNING_FILE")"
fi
if [[ -n "$SIGNING_IDENTITY" && ! "$SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "oops signing identity must be a certificate SHA-1 fingerprint." >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
# OOPS_PREVIEW=1 embeds the speech engine and asks for the microphone, in its own scratch path so switching
# doesn't rebuild the normal one. Package.swift reads the same variable; anything but 1 is a normal build.
PREVIEW=0
SCRATCH=(--scratch-path "$ROOT_DIR/.build")
if [[ "${OOPS_PREVIEW:-}" == 1 ]]; then
  PREVIEW=1
  SCRATCH=(--scratch-path "$ROOT_DIR/.build/preview")
  echo "Preview build (OOPS_PREVIEW=1): speech engine and microphone included; for this Mac only." >&2
else
  unset OOPS_PREVIEW
fi
# No Keychain lookup: resolving Sparkle from github.com can otherwise wait on a hidden prompt.
swift build --disable-sandbox --disable-keychain "${SCRATCH[@]}"
BIN_DIR="$(swift build --show-bin-path --disable-sandbox "${SCRATCH[@]}")"
PACKAGE_TMP_BASE="${TMPDIR:-/private/tmp}"
STAGING_DIR="$(mktemp -d "${PACKAGE_TMP_BASE%/}/oops-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
# Package and sign outside iCloud too: File Provider can reattach FinderInfo
# between attribute cleanup and codesign, even before the app is launched.
APP="$STAGING_DIR/oops.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/oops" "$APP/Contents/MacOS/oops"
# Sparkle (updates) without its XPC services, which only sandboxed apps use. Development builds
# carry no feed, so the updater never starts; the framework is here because the binary links it.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/B/XPCServices"
# The speech engine, trimmed as release_bundle.py does: arm64 code only, no headers or module map.
ENGINE="$APP/Contents/Frameworks/CTranscribe.framework"
if [[ $PREVIEW == 1 ]]; then
  ditto "$BIN_DIR/CTranscribe.framework" "$ENGINE"
  for extra in Headers Modules; do rm -rf "${ENGINE:?}/$extra" "$ENGINE/Versions/A/$extra"; done
  if [[ "$(lipo -archs "$ENGINE/Versions/A/CTranscribe")" != arm64 ]]; then
    lipo "$ENGINE/Versions/A/CTranscribe" -thin arm64 -output "$ENGINE/Versions/A/CTranscribe"
  fi
fi
# Compile the layered Icon Composer source, including appearance variants.
xcrun actool "$ROOT_DIR/Resources/Oops.icon" "$ROOT_DIR/Resources/Assets.xcassets" \
  --compile "$APP/Contents/Resources" --output-format human-readable-text \
  --platform macosx --minimum-deployment-target 26.0 \
  --app-icon Oops --output-partial-info-plist "$STAGING_DIR/icon-info.plist"
# Previews for the small in-window mark; the app icon itself comes from Assets.car.
cp "$ROOT_DIR/Resources/OopsIcon.png" "$ROOT_DIR/Resources/OopsIcon-dark.png" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Brand"
cp "$ROOT_DIR"/Resources/Brand/*.pdf "$APP/Contents/Resources/Brand/"
# The drop's sound cues, rendered by design/sound/generate.py.
mkdir -p "$APP/Contents/Resources/Sounds"
cp "$ROOT_DIR"/Resources/Sounds/*.caf "$APP/Contents/Resources/Sounds/"
# Onboarding's keys, swell and wave notes, rendered by design/onboarding/sound/make.py.
mkdir -p "$APP/Contents/Resources/Sounds/Onboarding"
cp "$ROOT_DIR"/Resources/Sounds/Onboarding/*.caf "$APP/Contents/Resources/Sounds/Onboarding/"
# Hello's ShaderGradient: shaders compiled at run time, and its environment light.
mkdir -p "$APP/Contents/Resources/Shaders" "$APP/Contents/Resources/Gradient"
cp "$ROOT_DIR"/Resources/Shaders/*.metal "$APP/Contents/Resources/Shaders/"
cp "$ROOT_DIR"/Resources/Gradient/*.bin "$APP/Contents/Resources/Gradient/"
# About → Changelog reads the repository's changelog.
if [[ -f "$ROOT_DIR/CHANGELOG.md" ]]; then cp "$ROOT_DIR/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"; fi
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>oops</string>
<key>CFBundleIdentifier</key><string>dev.0xmrwn.oops</string>
<key>CFBundleName</key><string>Oops</string>
<key>CFBundleDisplayName</key><string>Oops</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAccessibilityUsageDescription</key><string>Correct and revert text in the focused message composer when you press your Oops shortcuts.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge $STAGING_DIR/icon-info.plist" "$APP/Contents/Info.plist"
# The same text as release_bundle.py's MICROPHONE_USAGE.
MICROPHONE_USAGE="Oops listens while you dictate, and only then."
ENTITLEMENTS=()
if [[ $PREVIEW == 1 ]]; then
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string $MICROPHONE_USAGE" "$APP/Contents/Info.plist"
  cat >"$STAGING_DIR/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
  ENTITLEMENTS=(--entitlements "$STAGING_DIR/entitlements.plist")
fi
# A review has its own defaults domain and never replaces the installed development app.
BUNDLE_ID="dev.0xmrwn.oops"
if [[ "$MODE" == "--brand-review" ]]; then
  BUNDLE_ID="dev.0xmrwn.oops.brand-review"
  /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi
# Use the configured certificate across builds. A configured identity that is
# unavailable fails signing; never silently downgrade it to ad-hoc signing.
# Finder can add bundle presentation metadata while the development app is open.
# Remove only those non-code attributes from our generated artifact before signing.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
# Nested code first, inside out, then the app: never --deep, which Sparkle's helpers must not get.
sign_nested() {
  local code nested=("$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK")
  if [[ $PREVIEW == 1 ]]; then nested+=("$ENGINE"); fi
  for code in "${nested[@]}"; do
    codesign --force --sign "$1" --timestamp=none "$code" >/dev/null
  done
}
# ${ENTITLEMENTS[@]+…}: bash 3.2 (macOS) treats an empty array as unset under set -u.
if [[ -n "$SIGNING_IDENTITY" ]]; then
  sign_nested "$SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} "$APP" >/dev/null
  if codesign -dv "$APP" 2>&1 | grep -q '^TeamIdentifier=not set'; then
    # Self-signed: pin the certificate. Keychain still keys such builds to their code hash,
    # so each rebuild asks for the ChatGPT sign-in again; an Apple Development identity
    # carries a team ID that Keychain and Accessibility both keep across rebuilds.
    REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SIGNING_IDENTITY\""
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} \
      --requirements "=designated => $REQUIREMENT" "$APP" >/dev/null
    codesign --verify --deep --strict -R "=$REQUIREMENT" "$APP"
  else
    codesign --verify --deep --strict "$APP"
  fi
else
  echo "No local signing identity configured; using ad-hoc signing." >&2
  sign_nested -
  codesign --force --sign - ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} "$APP" >/dev/null
fi
mkdir -p "$ROOT_DIR/dist"
DIST_APP="$ROOT_DIR/dist/oops.app"
if [[ "$MODE" == "--brand-review" ]]; then DIST_APP="$ROOT_DIR/dist/oops-brand-review.app"; fi
# ditto merges into an existing bundle, so files removed from the app would survive and
# break its seal: replace the bundle. Attributes can still reattach after a move out of iCloud.
rm -rf "$DIST_APP"
ditto --norsrc --noextattr "$APP" "$DIST_APP"
xattr -dr com.apple.FinderInfo "$DIST_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$DIST_APP" 2>/dev/null || true
codesign --verify --deep --strict "$DIST_APP"
# The engine, the microphone text and the entitlement come together, and only with OOPS_PREVIEW=1.
verify_preview() {
  local app=$1 found=0 entitled=0 described=0 entitlements
  [[ -e "$app/Contents/Frameworks/CTranscribe.framework" ]] && found=1
  entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
  [[ $entitlements == *com.apple.security.device.audio-input* ]] && entitled=1
  /usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$app/Contents/Info.plist" >/dev/null 2>&1 && described=1
  if [[ "$found$entitled$described" != "$PREVIEW$PREVIEW$PREVIEW" ]]; then
    echo "$app: engine $found, audio-input entitlement $entitled, microphone text $described; expected $PREVIEW for each (OOPS_PREVIEW=$PREVIEW)." >&2
    return 1
  fi
  [[ $PREVIEW == 1 ]] || return 0
  local engine="$app/Contents/Frameworks/CTranscribe.framework/Versions/A"
  if [[ "$(lipo -archs "$engine/CTranscribe")" != arm64 || -e "$engine/Headers" || -e "$engine/Modules" ]] ||
    ! codesign --verify --strict "$engine/../.."; then
    echo "$app: CTranscribe.framework is not thinned to arm64, trimmed and signed." >&2
    return 1
  fi
}
verify_preview "$DIST_APP"
# Run outside Documents/iCloud: File Provider can reattach prohibited FinderInfo
# metadata to signed bundles even after a successful local signing step.
RUN_APP="$HOME/Library/Application Support/oops/Development/oops.app"
if [[ "$MODE" != "--build-only" && "$MODE" != "--brand-review" ]]; then
  # Preserve the running app and its recovery record until replacement is ready.
  pkill -x oops >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$RUN_APP")"
  rm -rf "$RUN_APP"
  ditto --norsrc --noextattr "$APP" "$RUN_APP"
  xattr -dr com.apple.FinderInfo "$RUN_APP" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "$RUN_APP" 2>/dev/null || true
  codesign --verify --deep --strict "$RUN_APP"
fi
case "$MODE" in
  --build-only) ;;
  --brand-review) /usr/bin/open -n "$DIST_APP" --args --hello-only --brand-review "${@:2}" ;;
  run) /usr/bin/open -n "$RUN_APP" ;;
  --verify)
    /usr/bin/open -n "$RUN_APP"
    sleep 1
    pgrep -x oops >/dev/null
    ;;
  --debug) lldb -- "$RUN_APP/Contents/MacOS/oops" ;;
  --logs | --telemetry)
    /usr/bin/open -n "$RUN_APP"
    /usr/bin/log stream --info --style compact --predicate 'process == "oops"'
    ;;
  *)
    echo "usage: $0 [run|--build-only|--brand-review|--verify|--debug|--logs|--telemetry]" >&2
    exit 2
    ;;
esac
