#!/bin/bash
# Exercises install.sh against made-up home and Applications folders, with a local "release", so it
# never touches the real /Applications, the real home folder, or a running Copybook.
#
#   ./make-release.sh && Support/test-install.sh
#
# Needs dist/Copybook.zip (+ .sha256) from make-release.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ZIP="$ROOT/dist/Copybook.zip"
[ -f "$ZIP" ] || { echo "Run ./make-release.sh first."; exit 1; }

BASE="$(mktemp -d "${TMPDIR:-/tmp}/copybook-install-test.XXXXXX")"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }

# Stand-ins for things that would touch the real machine: nothing is really quit, opened or registered.
SHIM="$BASE/shim"; mkdir -p "$SHIM"
cat > "$SHIM/pgrep"    <<'EOF'
#!/bin/bash
[ -f "$COPYBOOK_TEST_RUNNING" ] && exit 0; exit 1
EOF
cat > "$SHIM/osascript" <<'EOF'
#!/bin/bash
echo "quit requested" >> "$COPYBOOK_TEST_LOG"; rm -f "$COPYBOOK_TEST_RUNNING"; exit 0
EOF
cat > "$SHIM/pkill"    <<'EOF'
#!/bin/bash
echo "pkill $*" >> "$COPYBOOK_TEST_LOG"; exit 0
EOF
cat > "$SHIM/open"     <<'EOF'
#!/bin/bash
echo "open $*" >> "$COPYBOOK_TEST_LOG"; exit 0
EOF
cat > "$SHIM/lsregister" <<'EOF'
#!/bin/bash
echo "lsregister $*" >> "$COPYBOOK_TEST_LOG"; exit 0
EOF
cat > "$SHIM/xattr"    <<'EOF2'
#!/bin/bash
echo "xattr $*" >> "$COPYBOOK_TEST_LOG"; exec /usr/bin/xattr "$@"
EOF2
chmod +x "$SHIM"/*

# A fresh world: fake home (with a space in its name), fake /Applications, fake release.
new_world() {
  W="$(mktemp -d "$BASE/world.XXXXXX")"
  H="$W/my home"; SYS="$W/Applications"; mkdir -p "$H/Applications" "$H/Downloads" "$H/Library/Application Support/Copybook" "$SYS"
  REL="$W/release"; mkdir -p "$REL"; cp "$ZIP" "$REL/Copybook.zip"; (cd "$REL" && shasum -a 256 Copybook.zip > Copybook.zip.sha256)
  export COPYBOOK_TEST_LOG="$W/log.txt" COPYBOOK_TEST_RUNNING="$W/running"; : > "$COPYBOOK_TEST_LOG"; rm -f "$COPYBOOK_TEST_RUNNING"
}
# An "old" Copybook: the real app with another version number.
old_app() { ditto "$ROOT/build/Copybook.app" "$1"; /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${2:-0.5}" "$1/Contents/Info.plist"; }
other_app() { mkdir -p "$1/Contents"; /usr/bin/plutil -create xml1 "$1/Contents/Info.plist"; /usr/bin/plutil -insert CFBundleIdentifier -string "com.someone.else" "$1/Contents/Info.plist"; }
run_install() {   # args passed through; output in $OUT, status in $RC
  OUT="$(PATH="$SHIM:$PATH" HOME="$H" COPYBOOK_SYSTEM_APPS="$SYS" COPYBOOK_LSREGISTER="$SHIM/lsregister" \
         COPYBOOK_TTY="${ANSWERS:-/dev/null}" COPYBOOK_ZIP_URL="file://$REL/Copybook.zip" bash "$ROOT/install.sh" "$@" 2>&1)"; RC=$?
}
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
is_there()   { [ -e "$1" ] || [ -L "$1" ]; }
quarantined(){ /usr/bin/xattr -lr "$1" 2>/dev/null | grep -q quarantine; }

echo "A. Clean Mac: nothing installed yet"
new_world; run_install --no-open
check "exit 0" '[ $RC -eq 0 ]'
check "installed in the system folder" 'is_there "$SYS/Copybook.app"'
check "version is the release's" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ]'
check "no quarantine mark" '! quarantined "$SYS/Copybook.app"'
check "ran the xattr command" 'grep -q "xattr -dr com.apple.quarantine" <<<"$OUT"'
check "left no staging files" '! ls -A "$SYS" | grep -q "^\.Copybook"'
check "did not open it (--no-open)" '! grep -q "^open" "$COPYBOOK_TEST_LOG"'

echo "B. Earlier copies: system folder, ~/Applications, a renamed one, one in Downloads"
new_world
old_app "$SYS/Copybook.app" 0.5
old_app "$H/Applications/Copybook.app" 0.4
old_app "$H/Applications/Copybook 2.app" 0.3
old_app "$H/Downloads/Copybook.app" 0.2
run_install --no-open
check "exit 0" '[ $RC -eq 0 ]'
check "system copy replaced by the new version" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ]'
check "~/Applications copy removed" '! is_there "$H/Applications/Copybook.app"'
check "renamed copy removed" '! is_there "$H/Applications/Copybook 2.app"'
check "Downloads copy left alone" 'is_there "$H/Downloads/Copybook.app"'
check "Downloads copy reported as not touched" 'grep -q "Downloads/Copybook.app.*not touched" <<<"$OUT"'
check "exactly one copy in the Applications folders" '[ "$(ls "$SYS" "$H/Applications" | grep -c "\.app")" = 1 ]'
check "removed copies unregistered with macOS" 'grep -q "lsregister -u" "$COPYBOOK_TEST_LOG"'

echo "C. Running it again (same version)"
run_install --no-open
check "exit 0" '[ $RC -eq 0 ]'
check "says already installed" 'grep -q "already installed" <<<"$OUT"'
check "still one copy" '[ "$(ls "$SYS" "$H/Applications" | grep -c "\.app")" = 1 ]'
check "no quarantine mark" '! quarantined "$SYS/Copybook.app"'

echo "D. Only a developer's ~/Applications copy exists (the usual build.sh --install)"
new_world
old_app "$H/Applications/Copybook.app" 0.9
run_install --no-open
check "installed to the system folder" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ]'
check "~/Applications copy removed" '! is_there "$H/Applications/Copybook.app"'

echo "E. --user installs to ~/Applications and clears the system-folder copy"
new_world
old_app "$SYS/Copybook.app" 0.5
run_install --user --no-open
check "installed in ~/Applications" '[ "$(version_of "$H/Applications/Copybook.app")" = "1.0" ]'
check "system copy removed" '! is_there "$SYS/Copybook.app"'

echo "F. A copy recorded by earlier launches, in a custom folder; another unrecorded one"
new_world
mkdir -p "$H/Projects/Old" "$H/Projects/Other"
old_app "$H/Projects/Old/Copybook.app" 0.6
old_app "$H/Projects/Other/Copybook.app" 0.6
printf '{"apps":["%s"]}' "$H/Projects/Old/Copybook.app" > "$H/Library/Application Support/Copybook/footprint.json"
run_install --no-open
check "recorded copy removed" '! is_there "$H/Projects/Old/Copybook.app"'
check "unrecorded copy elsewhere left alone" 'is_there "$H/Projects/Other/Copybook.app"'

echo "G. A build folder inside a source checkout is never touched"
new_world
mkdir -p "$H/Applications/code/build"; touch "$H/Applications/code/Package.swift"
old_app "$H/Applications/code/build/Copybook.app" 0.6
run_install --no-open
check "developer build kept" 'is_there "$H/Applications/code/build/Copybook.app"'

echo "H. A different app that happens to be named Copybook.app"
new_world
other_app "$SYS/Copybook.app"
old_app "$H/Applications/Copybook.app" 0.5
run_install --no-open
check "refuses (non-zero exit)" '[ $RC -ne 0 ]'
check "other app untouched" '[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SYS/Copybook.app/Contents/Info.plist")" = "com.someone.else" ]'
check "nothing else removed" 'is_there "$H/Applications/Copybook.app"'

echo "I. --no-cleanup and --dry-run"
new_world
old_app "$SYS/Copybook.app" 0.5; old_app "$H/Applications/Copybook.app" 0.4
run_install --dry-run
check "dry run exit 0" '[ $RC -eq 0 ]'
check "dry run changed nothing" '[ "$(version_of "$SYS/Copybook.app")" = "0.5" ] && is_there "$H/Applications/Copybook.app"'
check "dry run lists the removal" 'grep -q "Would remove" <<<"$OUT"'
run_install --no-open --no-cleanup
check "--no-cleanup upgrades" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ]'
check "--no-cleanup keeps the duplicate" 'is_there "$H/Applications/Copybook.app"'

echo "J. Bad download: checksum mismatch leaves the old install alone"
new_world
old_app "$SYS/Copybook.app" 0.5; old_app "$H/Applications/Copybook.app" 0.4
echo "deadbeef  Copybook.zip" > "$REL/Copybook.zip.sha256"
run_install --no-open
check "fails" '[ $RC -ne 0 ]'
check "old install untouched" '[ "$(version_of "$SYS/Copybook.app")" = "0.5" ]'
check "duplicate untouched too" 'is_there "$H/Applications/Copybook.app"'

echo "K. Copybook is running: it is asked to quit first"
new_world
old_app "$SYS/Copybook.app" 0.5; touch "$COPYBOOK_TEST_RUNNING"
run_install --no-open
check "quit requested" 'grep -q "quit requested" "$COPYBOOK_TEST_LOG"'
check "installed" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ]'

echo "L. Install fails while copying: old version stays"
new_world
old_app "$SYS/Copybook.app" 0.5
mkdir -p "$W/failbin"; printf '#!/bin/bash\nexit 1\n' > "$W/failbin/ditto"; chmod +x "$W/failbin/ditto"
OUT="$(PATH="$SHIM:$PATH" HOME="$H" COPYBOOK_SYSTEM_APPS="$SYS" COPYBOOK_LSREGISTER="$SHIM/lsregister" COPYBOOK_ZIP_URL="file://$REL/Copybook.zip" \
       bash -c 'ditto() { if [[ "$2" == *".Copybook-installing"* ]]; then return 1; fi; command ditto "$@"; }; export -f ditto; bash "'"$ROOT"'/install.sh" --no-open' 2>&1)"; RC=$?
check "fails" '[ $RC -ne 0 ]'
check "old version still there" '[ "$(version_of "$SYS/Copybook.app")" = "0.5" ]'
check "no staging leftovers" '! ls -A "$SYS" | grep -q "^\.Copybook"'

echo "M. Final move fails: the previous version is put back"
new_world
old_app "$SYS/Copybook.app" 0.5
OUT="$(PATH="$SHIM:$PATH" HOME="$H" COPYBOOK_SYSTEM_APPS="$SYS" COPYBOOK_LSREGISTER="$SHIM/lsregister" COPYBOOK_ZIP_URL="file://$REL/Copybook.zip" \
       bash -c 'mv() { if [[ "$1" == *".Copybook-installing"* ]]; then return 1; fi; command mv "$@"; }; export -f mv; bash "'"$ROOT"'/install.sh" --no-open' 2>&1)"; RC=$?
check "fails" '[ $RC -ne 0 ]'
check "previous version restored" '[ "$(version_of "$SYS/Copybook.app")" = "0.5" ]'

echo "N. A duplicate that can't be deleted"
new_world
mkdir -p "$H/Applications/locked"; old_app "$H/Applications/locked/Copybook.app" 0.5
chmod a-w "$H/Applications/locked"
run_install --no-open
check "install still succeeds" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ]'
check "warns with the sudo command" 'grep -q "sudo rm -rf" <<<"$OUT"'
chmod u+w "$H/Applications/locked"

echo "O. A symlink standing in for the app: only the link is removed"
new_world
old_app "$H/Downloads/Real Copybook.app" 0.5
ln -s "$H/Downloads/Real Copybook.app" "$H/Applications/Copybook.app"
run_install --no-open
check "link removed" '! is_there "$H/Applications/Copybook.app"'
check "target left alone" 'is_there "$H/Downloads/Real Copybook.app/Contents/Info.plist"'

echo "P. Uninstall"
new_world
old_app "$SYS/Copybook.app" 0.5; old_app "$H/Applications/Copybook.app" 0.4; old_app "$H/Downloads/Copybook.app" 0.3
printf 'keep me' > "$H/Library/Application Support/Copybook/history.db"
run_install --uninstall
check "exit 0" '[ $RC -eq 0 ]'
check "Applications copies removed" '! is_there "$SYS/Copybook.app" && ! is_there "$H/Applications/Copybook.app"'
check "Downloads copy left alone" 'is_there "$H/Downloads/Copybook.app"'
check "clips untouched" '[ "$(cat "$H/Library/Application Support/Copybook/history.db")" = "keep me" ]'
run_install --uninstall
check "uninstall with nothing to remove is fine" '[ $RC -eq 0 ] && grep -q "No Copybook app found" <<<"$OUT"'

echo "Q. Clips and settings survive an update"
new_world
old_app "$SYS/Copybook.app" 0.5
printf 'my clips' > "$H/Library/Application Support/Copybook/history.db"
run_install --no-open
check "data intact" '[ "$(cat "$H/Library/Application Support/Copybook/history.db")" = "my clips" ]'

echo "R. Opens the app by default"
new_world; run_install
check "open was called on the installed app" 'grep -q "^open .*Applications/Copybook.app" "$COPYBOOK_TEST_LOG"'

echo "S. Asked what to do with a previous Copybook"
new_world; old_app "$SYS/Copybook.app" 0.5; old_app "$H/Applications/Copybook.app" 0.4
printf '2\n' > "$W/answers"; ANSWERS="$W/answers" run_install --no-open
check "says a previous Copybook was detected" 'grep -q "A previous Copybook was detected" <<<"$OUT"'
check "lists the copies it found" 'grep -q "version 0.5" <<<"$OUT" && grep -q "version 0.4" <<<"$OUT"'
check "offers replace and keep" 'grep -q "1) Replace" <<<"$OUT" && grep -q "2) Keep it, and install the new version next to it" <<<"$OUT"'
check "answer 2: exit 0" '[ $RC -eq 0 ]'
check "keep: the old Copybook is untouched" '[ "$(version_of "$SYS/Copybook.app")" = "0.5" ]'
check "keep: the new version is installed anyway, next to it" '[ "$(version_of "$SYS/Copybook 2.app")" = "1.0" ]'
check "keep: the other old copy was not removed" 'is_there "$H/Applications/Copybook.app"'
check "keep: ran the permission command on the new app" 'grep -q "xattr -dr com.apple.quarantine .*Copybook 2.app" "$COPYBOOK_TEST_LOG"'
check "keep: the new app is not quarantined" '! quarantined "$SYS/Copybook 2.app"'
printf '2\n' > "$W/answers"; ANSWERS="$W/answers" run_install --no-open
check "keeping again installs a third name instead of overwriting" '[ "$(version_of "$SYS/Copybook 3.app")" = "1.0" ] && [ "$(version_of "$SYS/Copybook 2.app")" = "1.0" ] && [ "$(version_of "$SYS/Copybook.app")" = "0.5" ]'

new_world; old_app "$SYS/Copybook.app" 0.5; old_app "$H/Applications/Copybook.app" 0.4
printf '\n' > "$W/answers"; ANSWERS="$W/answers" run_install --no-open
check "Enter replaces" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ] && ! is_there "$H/Applications/Copybook.app"'
check "replace: ran the permission command on the new app" 'grep -q "xattr -dr com.apple.quarantine .*Applications/Copybook.app" "$COPYBOOK_TEST_LOG"'

new_world; old_app "$SYS/Copybook.app" 0.5
printf 'maybe\nK\n' > "$W/answers"; ANSWERS="$W/answers" run_install --no-open
check "a wrong answer asks again, then K keeps the old one" 'grep -q "Press Enter to replace, or type 2 to keep" <<<"$OUT" && [ "$(version_of "$SYS/Copybook.app")" = "0.5" ] && [ "$(version_of "$SYS/Copybook 2.app")" = "1.0" ]'

new_world; old_app "$SYS/Copybook.app" 0.5
run_install --keep --no-open
check "--keep keeps the old one and installs the new one, without asking" '[ "$(version_of "$SYS/Copybook.app")" = "0.5" ] && [ "$(version_of "$SYS/Copybook 2.app")" = "1.0" ] && ! grep -q "Your choice" <<<"$OUT"'
new_world; old_app "$SYS/Copybook.app" 0.5
run_install --replace --no-open
check "--replace replaces without asking" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ] && ! grep -q "Your choice" <<<"$OUT" && ! is_there "$SYS/Copybook 2.app"'

new_world; run_install --no-open
check "no previous Copybook: nothing is asked" '! grep -q "Your choice" <<<"$OUT" && ! grep -q "previous Copybook" <<<"$OUT"'

new_world; old_app "$SYS/Copybook.app" 0.5
OUT="$(PATH="$SHIM:$PATH" HOME="$H" COPYBOOK_SYSTEM_APPS="$SYS" COPYBOOK_LSREGISTER="$SHIM/lsregister" COPYBOOK_TTY="$W/does-not-exist" \
       COPYBOOK_ZIP_URL="file://$REL/Copybook.zip" bash "$ROOT/install.sh" --no-open 2>&1)"; RC=$?
check "no terminal to ask in: replaces and says why" '[ "$(version_of "$SYS/Copybook.app")" = "1.0" ] && grep -q "no terminal to ask in" <<<"$OUT"'

echo
echo "$PASS passed, $FAIL failed.   (scratch folder: $BASE)"
[ "$FAIL" = 0 ]
