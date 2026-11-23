# make install     build from this checkout and install to /Applications (or ~/Applications)
# make uninstall   remove the app
# make release     build build/release/Copybook.zip for a GitHub release
install:
	./install.sh --build

uninstall:
	./install.sh --uninstall

release:
	./make-release.sh

.PHONY: install uninstall release
