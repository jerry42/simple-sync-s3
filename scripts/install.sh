#!/bin/bash
# Compile l'app, la copie dans /Applications et la lance.
#   ./scripts/install.sh            version standard
#   ./scripts/install.sh --sandbox  version App Sandbox
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh "$@"

# Quitte une copie en cours d'exécution (nom de processus, identifiant de l'app).
quit_app() {
    local process=$1 bundle_id=$2
    pgrep -xq "$process" || return 0
    echo "Quitting running $process…"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || pkill -x "$process" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq "$process" || break; sleep 0.5; done
}

quit_app SimpleSyncS3 com.jerry42.SimpleSyncS3

# Ancien nom de l'app : on l'arrête et on la retire, sinon elle continuerait à synchroniser
# (et à démarrer à l'ouverture de session). Sa configuration est reprise au premier lancement.
OLD=/Applications/MyDropbox.app
quit_app MyDropbox com.jerry42.MyDropbox
if [ -d "$OLD" ]; then
    rm -rf "$OLD"
    echo "Old version removed: $OLD (its configuration is taken over automatically)."
fi

DEST="/Applications/Simple Sync S3.app"
rm -rf "$DEST"
cp -R "build/Simple Sync S3.app" "$DEST"
# Juste après un arrêt, Launch Services peut refuser l'ouverture (erreur -600) : on réessaie.
open "$DEST" 2>/dev/null || { sleep 2; open "$DEST"; }
echo "Installed and launched: $DEST (cloud icon in the menu bar)."
echo "Help: app menu → Help, or open Resources/en.lproj/Help.html (French: Resources/fr.lproj/Help.html)"
