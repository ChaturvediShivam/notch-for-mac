#!/bin/bash
# One-time: creates a self-signed "Notch Local Signing" code-signing identity in your login keychain.
# Why: ad-hoc signed builds get a new identity on every rebuild, so macOS forgets the
# Screen Recording / Microphone / Speech permissions each time. With a stable identity it remembers.
# Undo: Keychain Access → login → My Certificates → delete "Notch Local Signing".
set -euo pipefail
NAME="Notch Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "Already exists: $NAME"; exit 0; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cs.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cs.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/n.p12" -passout pass:notch 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/n.p12" -passout pass:notch
security import "$TMP/n.p12" -k ~/Library/Keychains/login.keychain-db -P notch -T /usr/bin/codesign
echo "Created \"$NAME\". Now run ./scripts/make-app.sh, then grant permissions once more (last time)."
