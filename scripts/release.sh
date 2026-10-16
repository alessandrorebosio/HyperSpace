#!/bin/zsh
# Builds the release archive: runs the tests, builds build/HyperSpace.app, then zips it
# as build/HyperSpace-<version>.zip (ditto keeps the signature and permissions) and
# writes build/RELEASE-<version>.md, the release notes: the version's section of
# CHANGELOG.md plus the zip's SHA-256.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/HyperSpaceCore/HyperSpace.swift)
ZIP=build/HyperSpace-$VERSION.zip
NOTES=build/RELEASE-$VERSION.md

# The version's section, without its heading: from "## [<version>]" to the next "## [".
SECTION=$(awk -v v="## [$VERSION]" 'index($0, v) == 1 { on = 1; next } on && (/^## \[/ || /^\[[^]]+\]: /) { exit } on' CHANGELOG.md)
if [[ -z ${SECTION//[[:space:]]/} ]]; then
  echo "error: CHANGELOG.md has no section for $VERSION (\"## [$VERSION] - <date>\")" >&2
  exit 1
fi

scripts/test.sh
scripts/bundle.sh
rm -f $ZIP
ditto -c -k --sequesterRsrc --keepParent build/HyperSpace.app $ZIP

SHA=$(shasum -a 256 $ZIP | cut -d' ' -f1)
print -r -- "${SECTION}"$'\n\n'"## Install"$'\n\n'"Unzip \`HyperSpace-$VERSION.zip\` and move \`HyperSpace.app\` to \`/Applications\`, replacing the old one (the Accessibility permission is kept)."$'\n\n'"SHA-256: \`$SHA\`" | sed -e '/./,$!d' > $NOTES

echo "Built $ZIP"
echo "Notes in $NOTES"
echo "SHA-256 $SHA"
