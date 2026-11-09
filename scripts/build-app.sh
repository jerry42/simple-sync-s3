#!/bin/bash
# Compile en release et emballe le binaire dans « build/Simple Sync S3.app »
#   ./scripts/build-app.sh            app sans sandbox (comportement habituel)
#   ./scripts/build-app.sh --sandbox  app signée avec Resources/SimpleSyncS3.entitlements (App Sandbox)
# Variables facultatives :
#   S5_UNIVERSAL=1      binaire universel (Apple silicon + Intel), utilisé pour les releases
#   S5_VERSION=1.2.3    remplace CFBundleShortVersionString dans l'Info.plist de l'app
#   S5_SIGN_IDENTITY=…  identité de signature (voir plus bas)
set -euo pipefail
cd "$(dirname "$0")/.."

SANDBOX=0
case "${1:-}" in
    "") ;;
    --sandbox) SANDBOX=1 ;;
    *) echo "Usage: $0 [--sandbox]" >&2; exit 2 ;;
esac

BUILD_ARGS=(-c release)
if [ "${S5_UNIVERSAL:-0}" = 1 ]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
APP="build/Simple Sync S3.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SimpleSyncS3" "$APP/Contents/MacOS/SimpleSyncS3"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${S5_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $S5_VERSION" "$APP/Contents/Info.plist"
fi
# Traductions (Localizable.strings, InfoPlist.strings) et page d'aide, une copie par langue.
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Signature : identité de S5_SIGN_IDENTITY, sinon le certificat local créé par create-signing-cert.sh
# (ou celui de l'ancien nom de l'app), sinon « ad hoc » (macOS redemande alors les autorisations
# après chaque compilation).
IDENTITY="${S5_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    for NAME in "Simple Sync S3 Local Signing" "MyDropbox Local Signing"; do
        if security find-certificate -c "$NAME" >/dev/null 2>&1; then IDENTITY="$NAME"; break; fi
    done
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY=-
    echo "Ad hoc signature: macOS will ask again for access to Documents after each update." >&2
    echo "To avoid it, once: ./scripts/create-signing-cert.sh" >&2
fi
if [ "$SANDBOX" = 1 ]; then
    codesign --force --sign "$IDENTITY" --entitlements Resources/SimpleSyncS3.entitlements "$APP"
    echo "App ready (sandbox, signed with \"$IDENTITY\"): $(pwd)/$APP"
else
    codesign --force --sign "$IDENTITY" "$APP"
    echo "App ready (signed with \"$IDENTITY\"): $(pwd)/$APP"
fi
echo "To install it: ./scripts/install.sh"
