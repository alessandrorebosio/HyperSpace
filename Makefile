APP_NAME      := HyperSpace
CONFIG        ?= release
BUNDLE        := build/$(APP_NAME).app
BUNDLE_ID     := com.alessandrorebosio.HyperSpace
MIN_MACOS     := 13.0
# SDK_VERSION, SIGN_IDENTITY and TESTING_PLUGIN run xcrun or security. They are lazy and
# cached: evaluated once, and only by the recipes that use them, so `make clean` runs neither.
SDK_VERSION    = $(eval SDK_VERSION := $$(shell xcrun --show-sdk-version))$(SDK_VERSION)
# macOS ties the Accessibility grant to the app's designated requirement. When a
# "HyperSpace Dev" code signing certificate exists (see README) it is used: the grant is
# bound to that certificate. Otherwise the app is signed ad-hoc, whose default requirement
# is the binary's hash and changes on every build; we pin it to the bundle identifier
# instead so the grant survives rebuilds.
SIGN_IDENTITY ?= $(eval SIGN_IDENTITY := $$(shell security find-identity -p codesigning 2>/dev/null | grep -q '"HyperSpace Dev"' && echo "HyperSpace Dev" || echo -))$(SIGN_IDENTITY)
SIGN_REQUIREMENT = $(if $(filter -,$(SIGN_IDENTITY)),-r='designated => identifier "$(BUNDLE_ID)"')

.PHONY: build test app run install clean

build:
	swift build -c $(CONFIG)

# With only the Command Line Tools, SwiftPM does not always hand the Swift Testing macro
# plugin to the compiler ("plugin for module 'TestingMacros' not found"): pass it explicitly.
TESTING_PLUGIN  = $(eval TESTING_PLUGIN := $$(abspath $$(dir $$(shell xcrun --find swift))../lib/swift/host/plugins/testing/libTestingMacros.dylib))$(TESTING_PLUGIN)

test:
	swift test $(if $(wildcard $(TESTING_PLUGIN)),-Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN))

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" $(BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	strip -x $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	# SwiftPM records the deployment target (13.0) as the SDK version too, and AppKit then runs
	# the app in compatibility mode: the pre-Liquid Glass look on macOS 26 and later. Record the
	# SDK it was really built with.
	vtool -set-build-version macos $(MIN_MACOS) $(SDK_VERSION) -replace -output $(BUNDLE)/Contents/MacOS/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(SIGN_REQUIREMENT) $(BUNDLE)

run: app
	open $(BUNDLE)

# Quit a running copy first: replacing the bundle under it would leave the old binary running.
# The app quits on SIGTERM as from its menu (key remaps reset, parked windows brought back);
# wait up to 5 s for it to finish. Nothing running is fine.
install: app
	@pkill -x $(APP_NAME) && for i in $$(seq 50); do pgrep -qx $(APP_NAME) || break; sleep 0.1; done; true
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE) /Applications/

clean:
	rm -rf .build .build-clt .swiftpm build
