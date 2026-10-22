#!/usr/bin/env bash
# build-testflight.sh — Archive, export, and upload Zenith Player to TestFlight
#
# Prerequisites:
#   - Xcode 15+ installed
#   - .env file at repo root (see .env.example) with signing credentials
#   - Distribution certificate imported in login keychain
#   - ASC API private key at the path specified in .env
#
# Usage:
#   ./scripts/build-testflight.sh [--build-number N] [--skip-build] [--ipa PATH]
#
# The build number defaults to the current Unix timestamp (always incrementing).
# Use --skip-build to skip the archive/export and just upload an existing IPA.
# Use --ipa to specify a pre-built IPA path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── Load .env ────────────────────────────────────────────────────────────────
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
else
  echo "ERROR: .env file not found. Copy .env.example and fill in your values." >&2
  exit 1
fi

# ── Required env vars ────────────────────────────────────────────────────────
: "${TEAM_ID:?'TEAM_ID not set in .env'}"
: "${SIGN_IDENTITY:?'SIGN_IDENTITY not set in .env'}"
: "${PROFILE_UUID:?'PROFILE_UUID not set in .env'}"
: "${ASC_KEY_ID:?'ASC_KEY_ID not set in .env'}"
: "${ASC_ISSUER_ID:?'ASC_ISSUER_ID not set in .env'}"
: "${ASC_API_KEY_PATH:?'ASC_API_KEY_PATH not set in .env'}"

# ── Fixed configuration ──────────────────────────────────────────────────────
SCHEME="IPTVPlayer"
PROJECT="IPTVPlayer.xcodeproj"
: "${BUNDLE_ID:?'BUNDLE_ID not set in .env'}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

# ── Parse arguments ──────────────────────────────────────────────────────────
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"
SKIP_BUILD=false
IPA_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --ipa) IPA_PATH="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

ARCHIVE_PATH="/tmp/IPTVPlayer-${BUILD_NUMBER}.xcarchive"
EXPORT_DIR="/tmp/IPTVPlayer-${BUILD_NUMBER}-export"
EXPORT_PLIST="/tmp/IPTVPlayer-${BUILD_NUMBER}-ExportOptions.plist"
BUILD_DIR="$REPO_ROOT/build"
mkdir -p "$BUILD_DIR"

echo "=== Zenith Player TestFlight build ==="
echo "  Build number : $BUILD_NUMBER"

# ── Check S3 connectivity upfront ────────────────────────────────────────────
check_s3() {
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 10 --max-time 20 \
    "https://northamerica-1.object-storage.apple.com/" 2>/dev/null || echo "000")
  [[ "$http_code" != "000" ]]
}

echo ""
echo "▶ Checking Apple S3 connectivity…"
if check_s3; then
  echo "  ✓ Apple S3 reachable"
else
  echo "  ✗ Apple S3 unreachable (TLS blocked from this network)"
  echo ""
  echo "  The upload will fail. Options:"
  echo "    1. Connect to a VPN and re-run"
  echo "    2. Install Transporter from Mac App Store and drag the IPA"
  echo "    3. Wait and try later (the block is often transient)"
  echo ""
  if [[ "$SKIP_BUILD" == true ]] || [[ -n "$IPA_PATH" ]]; then
    echo "  Since you're doing upload-only, aborting."
    exit 2
  fi
  echo "  Continuing with build anyway — IPA will be saved to build/ for later upload."
  echo ""
fi

# ── Verify prerequisites ────────────────────────────────────────────────────
if [[ ! -f "$ASC_API_KEY_PATH" ]]; then
  echo "ERROR: ASC API key not found at $ASC_API_KEY_PATH" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$TEAM_ID"; then
  echo "ERROR: Distribution certificate for team $TEAM_ID not found in keychain." >&2
  exit 1
fi

# ── Build & Export ───────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]] && [[ -z "$IPA_PATH" ]]; then

  # Archive
  echo "▶ Archiving…"
  ARCHIVE_LOG="/tmp/archive-${BUILD_NUMBER}.log"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=tvOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    2>&1 | tee "$ARCHIVE_LOG" | grep -E "(error:|warning:|ARCHIVE SUCCEEDED|ARCHIVE FAILED)" || true

  if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo ""
    echo "ERROR: Archive failed. Last 30 lines:" >&2
    tail -30 "$ARCHIVE_LOG"
    exit 1
  fi
  echo "  ✓ Archive OK"

  # Verify archive
  APP_PATH="$ARCHIVE_PATH/Products/Applications/Zenith Player.app"
  echo ""
  echo "▶ Verifying archive…"
  ICON_COUNT=$(ls "$APP_PATH"/*.png 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$ICON_COUNT" -lt 6 ]]; then
    echo "  ERROR: Expected 6 loose PNGs, found $ICON_COUNT" >&2
    ls -la "$APP_PATH"/*.png 2>/dev/null
    exit 1
  fi
  echo "  ✓ $ICON_COUNT loose PNGs present"

  PLIST_ICON=$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon raw -o - "$APP_PATH/Info.plist" 2>/dev/null || echo "MISSING")
  echo "  ✓ CFBundlePrimaryIcon = $PLIST_ICON"
  if [[ "$PLIST_ICON" == "MISSING" ]]; then
    echo "  ERROR: CFBundlePrimaryIcon missing from built Info.plist" >&2
    exit 1
  fi

  # Export IPA (without uploading)
  echo ""
  echo "▶ Exporting IPA…"
  cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key>
        <string>${PROFILE_UUID}</string>
    </dict>
</dict>
</plist>
PLIST

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    2>&1 | tail -5

  IPA_PATH=$(find "$EXPORT_DIR" -name "*.ipa" -type f | head -1)
  if [[ -z "$IPA_PATH" ]]; then
    echo "  ERROR: No IPA produced in $EXPORT_DIR" >&2
    exit 1
  fi

  # Copy to build/ for persistence
  cp "$IPA_PATH" "$BUILD_DIR/Zenith Player.ipa"
  IPA_PATH="$BUILD_DIR/Zenith Player.ipa"
  echo "  ✓ IPA: $IPA_PATH ($(du -h "$IPA_PATH" | cut -f1))"
fi

# Use provided IPA if --ipa was given
if [[ -n "$IPA_PATH" ]] && [[ ! -f "$IPA_PATH" ]]; then
  echo "ERROR: IPA not found at $IPA_PATH" >&2
  exit 1
fi

# ── Upload ───────────────────────────────────────────────────────────────────
echo ""
echo "▶ Uploading to TestFlight…"

# Clear stale upload state that causes infinite retry loops
rm -rf "${HOME}/Library/Application Support/com.apple.dt.Xcode.ITunesSoftwareService/CDUploads" 2>/dev/null || true
mkdir -p "${HOME}/Library/Application Support/com.apple.dt.Xcode.ITunesSoftwareService/CDUploads"

# Re-check S3 before attempting upload
if ! check_s3; then
  echo ""
  echo "  ✗ Apple S3 still unreachable."
  echo ""
  echo "  IPA is ready at: $IPA_PATH"
  echo ""
  echo "  To upload later:"
  echo "    ./scripts/build-testflight.sh --skip-build --ipa \"$IPA_PATH\""
  echo ""
  echo "  Or use Transporter.app (Mac App Store) to drag & drop the IPA."
  exit 2
fi

# Upload with timeout and progress
UPLOAD_LOG="/tmp/upload-${BUILD_NUMBER}.log"
echo "  Using xcrun altool --upload-package…"
set +e
xcrun altool --upload-package "$IPA_PATH" \
  --type appletvos \
  --api-key "$ASC_KEY_ID" \
  --api-issuer "$ASC_ISSUER_ID" \
  --show-progress \
  2>&1 | tee "$UPLOAD_LOG"
UPLOAD_EXIT=${PIPESTATUS[0]}
set -e

if [[ $UPLOAD_EXIT -eq 0 ]]; then
  echo ""
  echo "✓ Build $BUILD_NUMBER submitted to TestFlight."
  echo "  Check: https://appstoreconnect.apple.com/apps"
  exit 0
fi

# altool failed — try xcodebuild -exportArchive with destination:upload
echo ""
echo "  altool failed (exit $UPLOAD_EXIT). Trying xcodebuild upload…"

cat > "${EXPORT_PLIST}.upload" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key>
        <string>${PROFILE_UUID}</string>
    </dict>
</dict>
</plist>
PLIST

# Clear stale state again
rm -rf "${HOME}/Library/Application Support/com.apple.dt.Xcode.ITunesSoftwareService/CDUploads" 2>/dev/null || true
mkdir -p "${HOME}/Library/Application Support/com.apple.dt.Xcode.ITunesSoftwareService/CDUploads"

set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "${EXPORT_DIR}-upload" \
  -exportOptionsPlist "${EXPORT_PLIST}.upload" \
  -authenticationKeyPath "$ASC_API_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  2>&1 | tee "${UPLOAD_LOG}.xcodebuild"
UPLOAD_EXIT=$?
set -e

if [[ $UPLOAD_EXIT -eq 0 ]]; then
  echo ""
  echo "✓ Build $BUILD_NUMBER submitted to TestFlight."
  echo "  Check: https://appstoreconnect.apple.com/apps"
  exit 0
fi

echo ""
echo "✗ Both upload methods failed."
echo ""
echo "  IPA is saved at: $IPA_PATH"
echo ""
echo "  To retry upload only:"
echo "    ./scripts/build-testflight.sh --skip-build --ipa \"$IPA_PATH\""
echo ""
echo "  Or drag the IPA into Transporter.app (free on Mac App Store)."
exit 1
