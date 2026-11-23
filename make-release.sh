#!/bin/bash
# Builds the app for download and points the Homebrew cask and npm package at it.
#
#   ./make-release.sh          -> dist/Copybook.zip and dist/Copybook.zip.sha256
#
# The two files in dist/ are committed to the repository; the installer downloads them from there.
# Then publish (replace 1.0 with the version in Support/Info.plist):
#   git add -A && git commit -m "Copybook 1.0" && git tag v1.0 && git push && git push --tags
set -euo pipefail
cd "$(dirname "$0")"

# One app that runs natively on both Apple silicon and Intel Macs.
COPYBOOK_UNIVERSAL=1 ./build.sh

APP=build/Copybook.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT=dist
rm -rf "$OUT"; mkdir -p "$OUT"

# ditto keeps the code signature and extended attributes intact, unlike zip.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Copybook.zip"
SUM=$(shasum -a 256 "$OUT/Copybook.zip" | awk '{print $1}')
echo "$SUM  Copybook.zip" > "$OUT/Copybook.zip.sha256"

# Keep the other install routes in step with this build.
sed -i '' -E "s/^( *version )\"[^\"]*\"/\1\"$VERSION\"/; s/^( *sha256 )\"[^\"]*\"/\1\"$SUM\"/" Casks/copybook.rb
NPM_VERSION="$VERSION"; while [ "$(echo "$NPM_VERSION" | tr -cd . | wc -c | tr -d ' ')" -lt 2 ]; do NPM_VERSION="$NPM_VERSION.0"; done   # npm wants x.y.z
sed -i '' -E "s/^(  \"version\": )\"[^\"]*\"/\1\"$NPM_VERSION\"/" package.json

echo
echo "Copybook $VERSION  ($(lipo -archs "$APP/Contents/MacOS/Copybook"))"
echo "  $OUT/Copybook.zip  ($(du -h "$OUT/Copybook.zip" | cut -f1))"
echo "  sha256 $SUM"
echo "Updated Casks/copybook.rb and package.json. Commit them, tag the commit v$VERSION, and push."
