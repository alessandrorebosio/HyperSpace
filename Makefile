APP_NAME      := HyperSpace
CONFIG        ?= release
BUNDLE        := build/$(APP_NAME).app
# "-" = ad-hoc. Use a stable identity (see README) so the Accessibility grant survives rebuilds.
SIGN_IDENTITY ?= -

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
