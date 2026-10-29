APP_NAME      := HyperSpace
CONFIG        ?= release
BUNDLE        := build/$(APP_NAME).app
BUNDLE_ID     := com.alessandrorebosio.HyperSpace
# macOS ties the Accessibility grant to the app's designated requirement. When a
# "HyperSpace Dev" code signing certificate exists (see README) it is used: the grant is
# bound to that certificate. Otherwise the app is signed ad-hoc, whose default requirement
# is the binary's hash and changes on every build; we pin it to the bundle identifier
# instead so the grant survives rebuilds.
SIGN_IDENTITY ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"HyperSpace Dev"' && echo "HyperSpace Dev" || echo -)
ifeq ($(SIGN_IDENTITY),-)
SIGN_REQUIREMENT := -r='designated => identifier "$(BUNDLE_ID)"'
endif

.PHONY: build test app run install clean

build:
	swift build -c $(CONFIG)

# Building the tests first avoids a stale-cache "TestingMacros plugin not found" error.
test:
	swift build --build-tests
	swift test

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" $(BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	strip -x $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(SIGN_REQUIREMENT) $(BUNDLE)

run: app
	open $(BUNDLE)

install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE) /Applications/

clean:
	rm -rf .build build
