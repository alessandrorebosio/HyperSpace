APP_NAME      := HyperSpace
CONFIG        ?= release
BUNDLE        := build/$(APP_NAME).app
# macOS ties the Accessibility grant to the signature. Ad-hoc ("-") signatures change on
# every build, so the grant is lost each time: when a "HyperSpace Dev" code signing
# certificate exists (see README) it is used automatically and the grant survives rebuilds.
SIGN_IDENTITY ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"HyperSpace Dev"' && echo "HyperSpace Dev" || echo -)

.PHONY: build app run install clean

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" $(BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	strip -x $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(BUNDLE)

run: app
	open $(BUNDLE)

install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE) /Applications/

clean:
	rm -rf .build build
