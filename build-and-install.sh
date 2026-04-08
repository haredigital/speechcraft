#!/usr/bin/env bash
# Build the hardened SpeechCraft fork from source and install to /Applications.
#
# Signing strategy:
# - We sign with an "Apple Development" certificate tied to the user's Apple ID
#   (haredigital@icloud.com). The cert has a stable Designated Requirement string
#   across rebuilds, so macOS TCC grants (Accessibility, Microphone, Apple Events)
#   PERSIST across code changes — no more "reset TCC and re-grant after every
#   rebuild" dance that adhoc signing forced.
# - The cert SHA1 is pinned below so this script works even if the user has
#   multiple signing identities in their Keychain. If the cert ever gets
#   regenerated, update SIGNING_IDENTITY_SHA.
# - If the pinned identity is not found, the script falls back to adhoc signing
#   so the build still works for new developers who haven't set up a cert yet.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$REPO_ROOT/speechcraft/speechcraft"
BUILD_DIR="$PROJECT_DIR/build"
SCHEME="SuperWhisper"  # upstream still uses the original scheme name
CONFIG="Release"
ENTITLEMENTS="$PROJECT_DIR/SpeechCraft/SpeechCraft.entitlements"
DEST_APP="/Applications/SpeechCraft.app"

# SHA1 of the Apple Development cert to sign with.
# Find yours via: security find-identity -v -p codesigning
# This is the cert tied to haredigital@icloud.com (9BFQL85XVJ).
SIGNING_IDENTITY_SHA="A11C8D7D2B1A373AEFD228459B297C3E7F173614"

# Resolve which signing identity to use
if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY_SHA"; then
  SIGN_IDENTITY="$SIGNING_IDENTITY_SHA"
  echo "==> Using pinned signing identity $SIGNING_IDENTITY_SHA"
else
  SIGN_IDENTITY="-"
  echo "==> WARNING: pinned identity not found, falling back to adhoc signing"
  echo "    (TCC permissions will reset on every rebuild)"
fi

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

echo "==> Signing with identity: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$BUILT_APP"

echo "==> Verifying signature"
codesign --verify --verbose=4 "$BUILT_APP"

echo "==> Verifying entitlements embedded"
codesign -d --entitlements - "$BUILT_APP" 2>&1 | tail -15

echo "==> Verifying signing identity in binary"
codesign -dv "$BUILT_APP" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier" | head -5

echo "==> Quitting any running SpeechCraft instance"
pkill -x SpeechCraft 2>/dev/null || true
sleep 1

echo "==> Installing to $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"
xattr -cr "$DEST_APP"

# Re-sign the installed copy too (xattr strip can invalidate the signature)
codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$DEST_APP"

echo "==> Done. Launching SpeechCraft..."
open "$DEST_APP"

echo
echo "If this is your first install with this signing identity, macOS will"
echo "re-prompt for microphone and accessibility permissions. AFTER that first"
echo "grant, all future rebuilds using the same identity will preserve the"
echo "permissions automatically — no more reset-and-re-grant dance."
