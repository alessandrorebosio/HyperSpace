#!/bin/zsh
# Runs the test suite. With Command Line Tools only (no Xcode), SwiftPM doesn't find the
# swift-testing macro plugin on its own, so we pass its path explicitly.
set -euo pipefail
cd "${0:A:h}/.."
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [[ -d $PLUGINS ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
