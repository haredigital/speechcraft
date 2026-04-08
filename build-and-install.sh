#!/usr/bin/env bash
# Build the hardened SpeechCraft fork from source and install to /Applications.
#
# Why this script exists:
# - The first build attempt used `CODE_SIGNING_ALLOWED=NO` which produced a
#   half-signed bundle Gatekeeper refused to run.
# - The fix requires an explicit `codesign --force --deep --sign -` step with
#   the entitlements file embedded, AFTER stripping any stray xattrs.
# - This script bakes in the correct sequence so future rebuilds Just Work.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$REPO_ROOT/speechcraft/speechcraft"
BUILD_DIR="$PROJECT_DIR/build"
SCHEME="SuperWhisper"  # upstream still uses the original scheme name
CONFIG="Release"
ENTITLEMENTS="$PROJECT_DIR/SpeechCraft/SpeechCraft.entitlements"
DEST_APP="/Applications/SpeechCraft.app"

echo "==> Building SpeechCraft ($CONFIG) from source"
cd "$PROJECT_DIR"
xcodebuild \
  -project SpeechCraft.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP="$BUILD_DIR/Build/Products/$CONFIG/SpeechCraft.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "ERROR: build did not produce $BUILT_APP" >&2
  exit 1
fi

echo "==> Stripping extended attributes from built bundle"
xattr -cr "$BUILT_APP"

echo "==> Re-signing adhoc with entitlements preserved"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$BUILT_APP"

echo "==> Verifying signature"
codesign --verify --verbose=4 "$BUILT_APP"

echo "==> Verifying entitlements embedded"
codesign -d --entitlements - "$BUILT_APP" 2>&1 | tail -15

echo "==> Quitting any running SpeechCraft instance"
pkill -x SpeechCraft 2>/dev/null || true
sleep 1

echo "==> Installing to $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"
xattr -cr "$DEST_APP"

# Re-sign the installed copy too (xattr strip can invalidate the signature)
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$DEST_APP"

echo "==> Done. Launching SpeechCraft..."
open "$DEST_APP"

echo
echo "If this is your first install with a different signing identity than"
echo "the previous one, macOS will re-prompt for microphone and accessibility"
echo "permissions. This is expected and NOT a sign of a problem."
