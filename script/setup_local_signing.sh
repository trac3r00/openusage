#!/usr/bin/env bash
# Creates a self-signed "OpenUsage Local Dev" code signing identity for Macs without an Apple
# Development certificate. build_and_run.sh signs with it, so every rebuild keeps the same designated
# requirement and the Keychain's "Always Allow" sticks instead of asking again after each build.
#
# The identity lives in its own keychain with an empty password, so codesign never prompts. It can
# only sign local dev builds; nothing trusts it. Safe to run again: it does nothing once set up.
set -euo pipefail

NAME="OpenUsage Local Dev"
KEYCHAIN="$HOME/Library/Keychains/openusage-dev-signing.keychain-db"

[ -f "$KEYCHAIN" ] || /usr/bin/security create-keychain -p "" "$KEYCHAIN"
/usr/bin/security unlock-keychain -p "" "$KEYCHAIN"
/usr/bin/security set-keychain-settings "$KEYCHAIN"

if ! /usr/bin/security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:openusage
  /usr/bin/security import "$WORK/identity.p12" -k "$KEYCHAIN" -P openusage -T /usr/bin/codesign >/dev/null
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null
fi

# codesign looks identities up in the user's keychain search list.
SEARCH=$(/usr/bin/security list-keychains -d user | tr -d '"' | xargs)
case " $SEARCH " in
  *" $KEYCHAIN "*) ;;
  *) /usr/bin/security list-keychains -d user -s $SEARCH "$KEYCHAIN" ;;
esac

echo "==> $NAME is ready in $KEYCHAIN"
