VERSION = 0.1.0
APP     = dist/vBootUSB.app

.PHONY: release icon app pkg install uninstall test clean

release:
	swift build -c release

icon:
	swift scripts/make-icon.swift Resources/AppIcon.iconset
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

app: release icon
	bash scripts/build-app.sh "$(VERSION)"

pkg: app
	bash scripts/build-pkg.sh "$(VERSION)"

install: app
	rm -rf /Applications/vBootUSB.app
	cp -R "$(APP)" /Applications/vBootUSB.app
	@echo "Installed: /Applications/vBootUSB.app"

uninstall:
	rm -rf /Applications/vBootUSB.app
	@echo "Removed: /Applications/vBootUSB.app"

test:
	swift test

clean:
	swift package clean
	rm -rf dist
