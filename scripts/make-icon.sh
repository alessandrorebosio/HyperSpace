#!/bin/zsh
# Renders Resources/AppIcon.icon (an Icon Composer document) into Resources/AppIcon.icns,
# the static fallback used when actool can't compile the Liquid Glass icon (see bundle.sh).
# Needs Xcode (for Icon Composer's ictool). Edit the icon with: open Resources/AppIcon.icon
set -euo pipefail
cd "${0:A:h}/.."

ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x $ICTOOL ]] || { echo "ictool not found: install Xcode" >&2; exit 1; }

SET=$(mktemp -d)/AppIcon.iconset
mkdir -p $SET
render() { "$ICTOOL" Resources/AppIcon.icon --export-image --platform macOS --rendition Default \
  --width $1 --height $1 --scale $2 --output-file $SET/$3 >/dev/null }
for size in 16 32 128 256 512; do
  render $size 1 icon_${size}x${size}.png
  render $size 2 icon_${size}x${size}@2x.png
done
iconutil -c icns $SET -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
