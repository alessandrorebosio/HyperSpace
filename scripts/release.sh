#!/bin/zsh
# Builds the release archive: runs the tests, builds build/HyperSpace.app, then zips it
# as build/HyperSpace-<version>.zip (ditto keeps the signature and permissions) and
# prints its SHA-256 for the release notes.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/HyperSpaceCore/HyperSpace.swift)
ZIP=build/HyperSpace-$VERSION.zip

scripts/test.sh
scripts/bundle.sh
rm -f $ZIP
ditto -c -k --sequesterRsrc --keepParent build/HyperSpace.app $ZIP

echo "Built $ZIP"
shasum -a 256 $ZIP
