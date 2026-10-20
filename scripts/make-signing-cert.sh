#!/usr/bin/env bash
# Creates a self-signed code-signing certificate, "Mountagent Desk Local Signing", in the login
# keychain. build-app.sh signs with it when no Developer ID is given, so the app keeps the
# same signature across builds and macOS remembers "Always Allow" answers (keychain access,
# notifications) instead of asking again after every build.
#
# Remove it any time in Keychain Access (login → My Certificates).
set -euo pipefail

NAME="Mountagent Desk Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in the login keychain."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
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
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASS" -name "$NAME"

# -T lets codesign use the key; macOS may still ask once on the first build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Added \"$NAME\" to the login keychain."
