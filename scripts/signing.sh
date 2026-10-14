#!/bin/zsh
# Creates (once) a self-signed "HyperSpace Dev" code signing identity in a keychain file private to
# this checkout (.signing/, git-ignored). The login keychain and system trust are not touched.
#
# Why: macOS ties the Accessibility permission to the app's signature. Ad hoc signatures change
# on every build, so the permission would be lost after each rebuild; this identity stays the same.
#
# Prints the keychain path on success.
set -euo pipefail
cd "${0:A:h}/.."

DIR=.signing
KEYCHAIN=$PWD/$DIR/hyperspace-dev.keychain-db
PASSWORD=hyperspace-dev # protects a throwaway local signing key, not a secret

if [[ ! -f $KEYCHAIN ]]; then
  mkdir -p $DIR
  TMP=$(mktemp -d)
  trap 'rm -rf $TMP' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=HyperSpace Dev" \
    -keyout $TMP/key.pem -out $TMP/cert.pem \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  # Legacy algorithms: `security import` can't read OpenSSL 3's default PKCS#12 encryption.
  openssl pkcs12 -export -legacy -inkey $TMP/key.pem -in $TMP/cert.pem \
    -out $TMP/signing.p12 -passout pass:$PASSWORD -name "HyperSpace Dev"
  security create-keychain -p $PASSWORD $KEYCHAIN
  security set-keychain-settings $KEYCHAIN # no auto-lock
  security import $TMP/signing.p12 -k $KEYCHAIN -P $PASSWORD -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k $PASSWORD $KEYCHAIN >/dev/null
fi

security unlock-keychain -p $PASSWORD $KEYCHAIN
echo $KEYCHAIN
