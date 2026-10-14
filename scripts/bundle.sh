#!/bin/zsh
# Builds build/Helm.app (release) with helmctl inside Contents/MacOS.
#
# Signing: set HELM_SIGN_IDENTITY to a code signing identity to keep the Accessibility
# permission across rebuilds. Without it the app is signed ad hoc, and macOS ties the
# permission to that exact build: after every rebuild it must be granted again.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product Helm
swift build -c release --product helmctl
BIN=$(swift build -c release --show-bin-path)

VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/HelmCore/Helm.swift)
BUNDLE_ID=$(sed -n 's/.*static let bundleID = "\(.*\)"/\1/p' Sources/HelmCore/Helm.swift)
APP=build/Helm.app

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/Helm $BIN/helmctl $APP/Contents/MacOS/

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>Helm</string>
    <key>CFBundleExecutable</key>          <string>Helm</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>      <string>15.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHumanReadableCopyright</key>    <string>Helm</string>
</dict>
</plist>
EOF

IDENTITY=${HELM_SIGN_IDENTITY:--}
codesign --force --options runtime --sign "$IDENTITY" $APP/Contents/MacOS/helmctl
codesign --force --options runtime --sign "$IDENTITY" --identifier "$BUNDLE_ID" $APP
codesign --verify --strict $APP

echo "Built $APP (signed: ${HELM_SIGN_IDENTITY:-ad hoc})"
