#!/bin/bash
# Crée, une seule fois, un certificat de signature de code auto-signé « Simple Sync S3 Local Signing »
# dans le trousseau de session. build-app.sh l'utilise ensuite automatiquement.
#
# Pourquoi : signée « ad hoc », l'app n'est reconnue par macOS qu'à l'empreinte exacte de son binaire,
# qui change à chaque compilation. Les autorisations (accès à Documents, trousseau) sont alors redemandées
# après chaque mise à jour. Avec un certificat stable, elles sont accordées une fois pour toutes.
set -euo pipefail

NAME="Simple Sync S3 Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

for EXISTING in "$NAME" "MyDropbox Local Signing"; do
    if security find-certificate -c "$EXISTING" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "Certificate \"$EXISTING\" already exists: nothing to do (build-app.sh uses it)."
        exit 0
    fi
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(uuidgen)

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# /usr/bin/openssl (LibreSSL d'Apple) : son format PKCS#12 est accepté par `security import`.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"
# -T : codesign peut utiliser la clé sans demander à chaque compilation.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Certificate \"$NAME\" created in your login keychain (valid 10 years)."
echo "Run ./scripts/install.sh again: macOS will ask for access to Documents one last time."
