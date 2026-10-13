#!/bin/bash
# One-time setup: creates a self-signed code signing identity in the login keychain.
# Builds signed with it keep the same identity, so macOS keeps privacy permissions
# (Full Disk Access) across updates. Not needed for building; without it the app is ad-hoc signed.
set -euo pipefail
NAME="QuickFind Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Zertifikat „$NAME“ ist bereits vorhanden."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

OPENSSL=/usr/bin/openssl
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(uuidgen)"
LEGACY=""
"$OPENSSL" version | grep -q "^OpenSSL 3" && LEGACY="-legacy"
"$OPENSSL" pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout "pass:$PASS"
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Zertifikat „$NAME“ wurde im Anmelde-Schlüsselbund angelegt."
