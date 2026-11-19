.PHONY: app run debug test icon install clean

app:
	@bash Scripts/build-app.sh release

run: app
	@open build/Muesli.app

debug:
	@swift build

test:
	@swift test

icon:
	@swift Scripts/make-icon.swift
	@echo "Wrote Support/AppIcon.icns"

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

install: app
	@mkdir -p ~/Applications
	@-$(LSREGISTER) -u build/Muesli.app >/dev/null 2>&1 || true
	@rm -rf ~/Applications/Muesli.app
	@mv build/Muesli.app ~/Applications/Muesli.app
	@-$(LSREGISTER) -f ~/Applications/Muesli.app >/dev/null 2>&1 || true
	@echo "Installed to ~/Applications/Muesli.app"

clean:
	@rm -rf .build build
