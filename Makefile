APP_NAME      := HyperSpace
CONFIG        ?= release
BUNDLE        := build/$(APP_NAME).app
BUNDLE_ID     := com.alessandrorebosio.HyperSpace
MIN_MACOS     := 13.0
# Extra flags for every swift build/test, e.g. SWIFT_FLAGS="--scratch-path .build-clt" (CI's
# Command Line Tools run, kept apart from the Xcode toolchain's .build).
SWIFT_FLAGS   ?=
# SDK_VERSION, SIGN_IDENTITY, TESTING_PLUGIN and TESTING_FRAMEWORKS run xcrun or security. They are lazy and
# cached: evaluated once, and only by the recipes that use them, so `make clean` runs neither.
SDK_VERSION    = $(eval SDK_VERSION := $$(shell xcrun --show-sdk-version))$(SDK_VERSION)
# macOS ties the Accessibility grant to the app's designated requirement. When a
# "HyperSpace Dev" code signing certificate exists (see docs/10) it is used: the grant is
# bound to that certificate. Otherwise the app is signed ad-hoc, whose default requirement
# is the binary's hash and changes on every build; we pin it to the bundle identifier
# instead so the grant survives rebuilds.
SIGN_IDENTITY ?= $(eval SIGN_IDENTITY := $$(shell security find-identity -p codesigning 2>/dev/null | grep -q '"HyperSpace Dev"' && echo "HyperSpace Dev" || echo -))$(SIGN_IDENTITY)
SIGN_REQUIREMENT = $(if $(filter -,$(SIGN_IDENTITY)),-r='designated => identifier "$(BUNDLE_ID)"')
# Quits a running copy, wherever it was started from. The app quits on SIGTERM as from its
# menu (key remaps reset, parked windows brought back); wait up to 5 s for it to finish.
# Nothing running is fine.
QUIT_RUNNING   = pkill -x $(APP_NAME) && for i in $$(seq 50); do pgrep -qx $(APP_NAME) || break; sleep 0.1; done; true

.PHONY: build test app run install icon clean

build:
	swift build -c $(CONFIG) $(SWIFT_FLAGS)

# With only the Command Line Tools, SwiftPM does not always hand the Swift Testing macro
# plugin to the compiler ("plugin for module 'TestingMacros' not found"): pass it explicitly.
TESTING_PLUGIN  = $(eval TESTING_PLUGIN := $$(abspath $$(dir $$(shell xcrun --find swift))../lib/swift/host/plugins/testing/libTestingMacros.dylib))$(TESTING_PLUGIN)

# Older Command Line Tools (Swift 6.3) keep the Testing framework in Library/Developer/Frameworks
# and its lib_TestingInterop.dylib in Library/Developer/usr/lib, but SwiftPM looks in
# Developer/Library/Frameworks ("no such module 'Testing'", then "Library not loaded:
# @rpath/lib_TestingInterop.dylib"): name the folders for the compiler, the linker and the test
# bundle's run path. Xcode's toolchain has no such folder.
TESTING_FRAMEWORKS = $(eval TESTING_FRAMEWORKS := $$(abspath $$(dir $$(shell xcrun --find swift))../../Library/Developer/Frameworks))$(TESTING_FRAMEWORKS)
TESTING_LIBS    = $(abspath $(TESTING_FRAMEWORKS)/../usr/lib)
TESTING_FLAGS   = $(if $(wildcard $(TESTING_PLUGIN)),-Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN)) \
                  $(if $(wildcard $(TESTING_FRAMEWORKS)/Testing.framework),-Xswiftc -F -Xswiftc $(TESTING_FRAMEWORKS) -Xlinker -F -Xlinker $(TESTING_FRAMEWORKS) -Xlinker -rpath -Xlinker $(TESTING_FRAMEWORKS)) \
                  $(if $(wildcard $(TESTING_LIBS)/lib_TestingInterop.dylib),-Xlinker -rpath -Xlinker $(TESTING_LIBS))

test:
	swift test $(SWIFT_FLAGS) $(TESTING_FLAGS)

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) $(SWIFT_FLAGS) --show-bin-path)/$(APP_NAME)" $(BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	# One source for the minimum macOS: the bundle says what the binary is stamped with below.
	plutil -replace LSMinimumSystemVersion -string $(MIN_MACOS) $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	strip -x $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	# SwiftPM records the deployment target (13.0) as the SDK version too, and AppKit then runs
	# the app in compatibility mode: the pre-Liquid Glass look on macOS 26 and later. Record the
	# SDK it was really built with.
	vtool -set-build-version macos $(MIN_MACOS) $(SDK_VERSION) -replace -output $(BUNDLE)/Contents/MacOS/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(SIGN_REQUIREMENT) $(BUNDLE)

# Build first, so a build error leaves the running copy alone; then quit it before the bundle
# is replaced: `open` on a running app only brings the old binary forward.
run: build
	@$(QUIT_RUNNING)
	$(MAKE) app
	open $(BUNDLE)

# Quit a running copy first: replacing the bundle under it would leave the old binary running.
install: app
	@$(QUIT_RUNNING)
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE) /Applications/

# Redraws Resources/AppIcon.icns. The script needs Pillow, which is not part of the build.
icon:
	@python3 -c 'import PIL' 2>/dev/null || { echo "make icon needs Pillow: pip3 install pillow"; exit 1; }
	python3 scripts/make-icon.py

clean:
	rm -rf .build .build-clt .swiftpm build
