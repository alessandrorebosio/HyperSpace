#!/bin/zsh
# Builds build/HyperSpace.app (release) with hsctl inside Contents/MacOS.
#
# Signing: always with a stable identity, so macOS keeps the Accessibility permission across
# rebuilds (an ad hoc signature changes on every build and the permission would be lost).
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product HyperSpace
swift build -c release --product hsctl
BIN=$(swift build -c release --show-bin-path)

VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/HyperSpaceCore/HyperSpace.swift)
BUNDLE_ID=$(sed -n 's/.*static let bundleID = "\(.*\)"/\1/p' Sources/HyperSpaceCore/HyperSpace.swift)
APP=build/HyperSpace.app

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/HyperSpace $BIN/hsctl $APP/Contents/MacOS/
# Icon: Liquid Glass from the Icon Composer document when Xcode's actool can compile it
# (adapts to dark/clear/tinted), plus the static AppIcon.icns from scripts/make-icon.sh.
cp Resources/AppIcon.icns $APP/Contents/Resources/
XCODE=/Applications/Xcode.app/Contents/Developer
if [[ -d $XCODE ]] && DEVELOPER_DIR=$XCODE xcrun actool Resources/AppIcon.icon --compile $APP/Contents/Resources \
     --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon \
     --output-partial-info-plist $(mktemp) >/dev/null 2>&1; then
  ICON_NAME="<key>CFBundleIconName</key>            <string>AppIcon</string>"
else
  echo "note: actool unavailable (accept the Xcode license with: sudo xcodebuild -license); using the static icon"
  ICON_NAME=""
fi
strip -x $APP/Contents/MacOS/HyperSpace $APP/Contents/MacOS/hsctl # local symbols only: ~40% smaller

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>HyperSpace</string>
    <key>CFBundleExecutable</key>          <string>HyperSpace</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    $ICON_NAME
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>      <string>15.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHumanReadableCopyright</key>    <string>HyperSpace</string>
</dict>
</plist>
EOF

# Identity: $HYPERSPACE_SIGN_IDENTITY, else the project's own "HyperSpace Dev" keychain (created on first
# run by scripts/signing.sh). Both are stable, so the Accessibility permission survives rebuilds.
SIGN=(--sign "${HYPERSPACE_SIGN_IDENTITY:-}")
if [[ -z "${HYPERSPACE_SIGN_IDENTITY:-}" ]]; then
  KEYCHAIN=$(scripts/signing.sh)
  SIGN=(--keychain "$KEYCHAIN" --sign "HyperSpace Dev")
fi
codesign --force --options runtime "${SIGN[@]}" $APP/Contents/MacOS/hsctl
codesign --force --options runtime "${SIGN[@]}" --identifier "$BUNDLE_ID" $APP
codesign --verify --strict $APP

echo "Built $APP (signed: ${HYPERSPACE_SIGN_IDENTITY:-HyperSpace Dev, project keychain})"
