#!/bin/bash
# Compile en release et emballe le binaire dans « build/Simple Sync S3.app »
#   ./scripts/build-app.sh            app sans sandbox (comportement habituel)
#   ./scripts/build-app.sh --sandbox  app signée avec Resources/SimpleSyncS3.entitlements (App Sandbox)
set -euo pipefail
cd "$(dirname "$0")/.."

SANDBOX=0
case "${1:-}" in
    "") ;;
    --sandbox) SANDBOX=1 ;;
    *) echo "Usage : $0 [--sandbox]" >&2; exit 2 ;;
esac

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="build/Simple Sync S3.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SimpleSyncS3" "$APP/Contents/MacOS/SimpleSyncS3"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Aide.html "$APP/Contents/Resources/Aide.html"
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
    echo "Signature ad hoc : l'accès à Documents sera redemandé après chaque mise à jour." >&2
    echo "Pour l'éviter, une seule fois : ./scripts/create-signing-cert.sh" >&2
fi
if [ "$SANDBOX" = 1 ]; then
    codesign --force --sign "$IDENTITY" --entitlements Resources/SimpleSyncS3.entitlements "$APP"
    echo "App prête (sandbox, signée « $IDENTITY ») : $(pwd)/$APP"
else
    codesign --force --sign "$IDENTITY" "$APP"
    echo "App prête (signée « $IDENTITY ») : $(pwd)/$APP"
fi
echo "Pour l'installer : ./scripts/install.sh"
