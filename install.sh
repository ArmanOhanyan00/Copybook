#!/bin/bash
# Installs (or updates) Copybook on this Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/ArmanOhanyan00/Copybook/main/install.sh | bash
#
# What it does, in order:
#   1. looks for Copybook copies already on this Mac. If it finds one, it says so and asks in the
#      terminal: press Enter to replace it with the new version, or type 2 to keep the old one and
#      install the new version next to it
#   2. downloads the latest release (or builds from source if you ask, or on a Mac the release doesn't cover)
#   3. checks the download against its published SHA-256 checksum
#   4. quits Copybook if it is running and swaps the new app in; the old one is put back if anything fails
#   5. runs:  xattr -dr com.apple.quarantine /Applications/Copybook.app
#      Copybook isn't signed with a paid Apple Developer ID, so macOS would otherwise refuse to open
#      it with "can't be opened". That command only clears the "downloaded from the internet" mark
#      on this one app.
#   6. removes older duplicate copies from the Applications folders, then opens Copybook
#
# Your clips and settings are never touched by an install or update.
#
# Options (pass after `bash -s --` when piping):
#   --version 1.0   install a specific release instead of the latest
#   --build         build from source instead of downloading the app (needs Xcode Command Line Tools)
#   --user          install to ~/Applications instead of /Applications
#   --replace       don't ask: replace a previous Copybook (also --yes)
#   --keep          don't ask: keep a previous Copybook and install the new version next to it
#   --no-cleanup    don't remove other Copybook copies
#   --dry-run       show what would be installed and removed, and change nothing
#   --no-open       don't launch Copybook afterwards
#   --uninstall     quit Copybook and remove every copy of the app (your data stays; use
#                   Settings > About > Delete Everything first if you want that gone too)
#   --help
#
# With no terminal to ask in (a script, CI), a previous Copybook is replaced.
#
# Environment: COPYBOOK_REPO (owner/name), COPYBOOK_VERSION, COPYBOOK_ZIP_URL (use another download),
#              COPYBOOK_REF (branch or tag used for --build, default main).

# Everything lives in main() and runs on the last line, so a half-downloaded script does nothing.
main() {
  set -euo pipefail

  local REPO="${COPYBOOK_REPO:-ArmanOhanyan00/Copybook}"
  local VERSION="${COPYBOOK_VERSION:-latest}"
  local REF="${COPYBOOK_REF:-main}"
  local BUILD=0 USER_ONLY=0 OPEN=1 UNINSTALL=0 CLEANUP=1 DRY=0 MODE=ask
  local APP_NAME="Copybook.app" BUNDLE_ID="local.copybook.app"
  local SYS_APPS="${COPYBOOK_SYSTEM_APPS:-/Applications}"      # overridable so tests never touch the real folder
  local USER_APPS="$HOME/Applications"
  local LSREGISTER="${COPYBOOK_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --version)    VERSION="${2:?--version needs a number, for example 1.0}"; shift ;;
      --build)      BUILD=1 ;;
      --user)       USER_ONLY=1 ;;
      --replace|--yes|-y) MODE=replace ;;
      --keep)       MODE=keep ;;
      --no-cleanup) CLEANUP=0 ;;
      --dry-run)    DRY=1 ;;
      --no-open)    OPEN=0 ;;
      --uninstall)  UNINSTALL=1 ;;
      -h|--help)    sed -n '2,/^$/p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "Unknown option: $1 (try --help)" >&2; return 2 ;;
    esac
    shift
  done
  VERSION="${VERSION#v}"

  say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
  note() { printf '    %s\n' "$*"; }
  warn() { printf '\033[33mNote:\033[0m %s\n' "$*" >&2; }
  die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
  tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

  [ "$(uname -s)" = "Darwin" ] || die "Copybook is a macOS app, and this isn't a Mac."
  local macos_major; macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$macos_major" -ge 14 ] || die "Copybook needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

  local WORK; WORK="$(mktemp -d "${TMPDIR:-/tmp}/copybook-install.XXXXXX")"
  trap "rm -rf '$WORK'" EXIT   # expanded now: WORK is local to main and gone by the time the trap runs
  local WORK_REAL; WORK_REAL="$(cd "$WORK" && pwd -P)"

  # ---------- helpers: finding Copybook copies ----------

  bundle_id()  { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true; }
  bundle_ver() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }
  # The folder is resolved (so /tmp and /private/tmp compare equal); the app's own name is left as it is.
  real() { local d; d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1; printf '%s/%s\n' "$d" "$(basename "$1")"; }

  local SYS_REAL USER_REAL HOME_REAL p
  SYS_REAL="$(cd "$SYS_APPS" 2>/dev/null && pwd -P || echo "$SYS_APPS")"
  HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
  USER_REAL="$HOME_REAL/Applications"

  # Where earlier launches of Copybook recorded having run from (Copybook keeps this list itself).
  : > "$WORK/manifest.txt"
  local MANIFEST="$HOME/Library/Application Support/Copybook/footprint.json"
  if [ -f "$MANIFEST" ]; then
    plutil -extract apps xml1 -o - "$MANIFEST" 2>/dev/null | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' > "$WORK/manifest.raw" || true
    while IFS= read -r p; do [ -n "$p" ] && { real "$p" 2>/dev/null || true; }; done < "$WORK/manifest.raw" > "$WORK/manifest.txt"
  fi

  # Every Copybook bundle we can find: the usual folders, anything earlier launches recorded, and
  # Spotlight's list. Each is checked by its bundle identifier, so a renamed copy is still found
  # and some other app that happens to be called Copybook never is.
  find_copies() {
    local d f
    {
      # The Applications folders and one level of folders inside them (Utilities, Launchpad groups...),
      # plus the places people tend to leave a downloaded app.
      for d in "$SYS_APPS" "$USER_APPS" "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents"; do
        for f in "$d"/*.app; do [ -e "$f" ] && printf '%s\n' "$f"; done
      done
      for d in "$SYS_APPS" "$USER_APPS"; do
        for f in "$d"/*/*.app; do [ -e "$f" ] && printf '%s\n' "$f"; done
      done
      cat "$WORK/manifest.txt"
      if command -v mdfind >/dev/null 2>&1; then
        perl -e 'alarm 8; exec @ARGV' mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true
      fi
    } | while IFS= read -r f; do
      [ -n "$f" ] && [ -d "$f" ] && [ "$(bundle_id "$f")" = "$BUNDLE_ID" ] || continue
      real "$f" || true
    done | sort -u
  }

  # What to do with a copy found at $1 (a resolved path). Prints "self", "remove" or "keep: <why>".
  classify() {
    local p="$1" d i
    if [ -n "${DEST_REAL:-}" ] && [ "$p" = "$DEST_REAL" ]; then echo "self"; return; fi
    case "$p" in
      "$WORK_REAL"/*)                echo "keep: this installer's own files"; return ;;
      /Volumes/*)                    echo "keep: on a disk image or another disk"; return ;;
      */Caskroom/*)                  echo "keep: Homebrew's own backup"; return ;;
      */.Trash/*)                    echo "keep: in the Trash"; return ;;
      */AppTranslocation/*)           echo "keep: a temporary macOS copy"; return ;;
      /System/*)                     echo "keep: part of macOS"; return ;;
    esac
    d="$(dirname "$p")"
    for i in 1 2 3; do   # a build folder inside a source checkout is a developer's, not an install
      if [ -f "$d/Package.swift" ]; then echo "keep: inside a source checkout"; return; fi
      d="$(dirname "$d")"
    done
    case "$p" in
      "$SYS_REAL"/*|"$USER_REAL"/*) echo "remove"; return ;;
    esac
    if grep -qxF -- "$p" "$WORK/manifest.txt" 2>/dev/null; then
      case "$p" in "$HOME_REAL"/*) echo "remove"; return ;; esac
    fi
    echo "keep: outside the Applications folders"
  }

  quit_all() {
    if pgrep -x Copybook >/dev/null 2>&1; then
      say "Quitting Copybook"
      osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
      local i=0; while pgrep -x Copybook >/dev/null 2>&1 && [ $i -lt 24 ]; do sleep 0.25; i=$((i+1)); done
      pkill -x Copybook 2>/dev/null || true
      sleep 0.3
    fi
  }

  local FAILED_REMOVALS=0
  remove_copy() {
    local p="$1"
    case "$p" in *.app) ;; *) return 1 ;; esac
    [ "$(bundle_id "$p")" = "$BUNDLE_ID" ] || return 1       # re-checked at the moment of deleting
    "$LSREGISTER" -u "$p" >/dev/null 2>&1 || true            # so macOS doesn't keep listing a ghost
    if [ -L "$p" ]; then rm -f -- "$p"; else rm -rf -- "$p" 2>/dev/null || true; fi
    if [ -e "$p" ] || [ -L "$p" ]; then
      warn "Couldn't remove $(tilde "$p") (it belongs to another user or is locked). Remove it with:  sudo rm -rf '$p'"
      FAILED_REMOVALS=$((FAILED_REMOVALS+1)); return 1
    fi
    note "Removed $(tilde "$p")"
  }

  # ---------- where it goes ----------

  local DEST_DIR="$SYS_APPS"
  if [ "$USER_ONLY" = 1 ] || [ ! -w "$SYS_APPS" ]; then
    DEST_DIR="$USER_APPS"
    if [ "$USER_ONLY" = 0 ] && [ "$UNINSTALL" = 0 ]; then
      note "$SYS_APPS isn't writable for this account, so Copybook goes in ~/Applications instead."
    fi
  fi
  local DEST="$DEST_DIR/$APP_NAME" DEST_REAL=""
  if [ "$UNINSTALL" = 0 ] && [ "$DRY" = 0 ]; then mkdir -p "$DEST_DIR"; fi
  if [ "$UNINSTALL" = 0 ]; then DEST_REAL="$(real "$DEST" || echo "$DEST")"; fi

  # ---------- what's already here ----------

  local DUPES="$WORK/dupes.txt" KEEPS="$WORK/keeps.txt" HAVE_SELF=0 SELF_VER=""
  : > "$DUPES"; : > "$KEEPS"
  local p cls why
  find_copies > "$WORK/found.txt"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    cls="$(classify "$p")"
    case "$cls" in
      self)   HAVE_SELF=1; SELF_VER="$(bundle_ver "$p")" ;;
      remove) printf '%s\n' "$p" >> "$DUPES" ;;
      keep:*) printf '%s|%s\n' "$p" "${cls#keep: }" >> "$KEEPS" ;;
    esac
  done < "$WORK/found.txt"

  if [ "$UNINSTALL" = 0 ] && { [ "$HAVE_SELF" = 1 ] || [ -s "$DUPES" ]; }; then
    say "A previous Copybook was detected on this Mac"
    if [ "$HAVE_SELF" = 1 ]; then note "$(tilde "$DEST")  (version $SELF_VER)"; fi
    while IFS= read -r p; do
      [ -n "$p" ] && note "$(tilde "$p")  (version $(bundle_ver "$p"))"
    done < "$DUPES"
    while IFS='|' read -r p why; do
      [ -n "$p" ] && note "$(tilde "$p")  (not touched: $why)"
    done < "$KEEPS"
    if [ -d "/opt/homebrew/Caskroom/copybook" ] || [ -d "/usr/local/Caskroom/copybook" ]; then
      note "Homebrew also lists Copybook. Replacing it here works; Homebrew keeps its own record."
    fi
  elif [ "$UNINSTALL" = 0 ] && [ -s "$KEEPS" ]; then
    # Only copies that are never touched (Downloads, a disk image, a source checkout...): no question to ask.
    while IFS='|' read -r p why; do
      [ -n "$p" ] && note "Another Copybook copy, not touched: $(tilde "$p") ($why)"
    done < "$KEEPS"
  fi

  # A different app that happens to be called Copybook.app must never be overwritten.
  if [ "$UNINSTALL" = 0 ] && { [ -e "$DEST" ] || [ -L "$DEST" ]; } && [ "$(bundle_id "$DEST")" != "$BUNDLE_ID" ]; then
    die "$(tilde "$DEST") is a different app that happens to be named Copybook, so it was left alone. Move it somewhere else and run this again."
  fi

  # ---------- uninstall ----------

  if [ "$UNINSTALL" = 1 ]; then
    local n=0
    # With no destination nothing counts as "self", so every copy in the Applications folders is removed.
    if [ "$DRY" = 1 ]; then
      while IFS= read -r p; do [ -n "$p" ] && note "Would remove $(tilde "$p")"; done < "$DUPES"
    else
      if [ -s "$DUPES" ]; then quit_all; fi
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if remove_copy "$p"; then n=$((n+1)); fi
      done < "$DUPES"
      if [ "$n" = 0 ] && [ "$FAILED_REMOVALS" = 0 ]; then note "No Copybook app found in the Applications folders."
      else say "Removed $n cop$([ "$n" = 1 ] && echo y || echo ies) of Copybook"; fi
    fi
    while IFS='|' read -r p why; do [ -n "$p" ] && note "Left alone: $(tilde "$p") ($why)"; done < "$KEEPS"
    note "Your clips and settings are untouched. To remove them too, use Settings > About > Delete Everything"
    note "before uninstalling, or delete ~/Library/Application Support/Copybook yourself."
    [ "$FAILED_REMOVALS" = 0 ] || return 1
    return 0
  fi

  if [ "$DRY" = 1 ]; then
    say "Dry run: nothing was changed"
    note "Would install Copybook ($VERSION) to $(tilde "$DEST")"
    if [ "$CLEANUP" = 1 ]; then
      while IFS= read -r p; do [ -n "$p" ] && note "Would remove $(tilde "$p")"; done < "$DUPES"
    fi
    return 0
  fi

  # ---------- a previous Copybook: keep it or replace it ----------

  ask_keep_or_replace() {
    CHOICE=replace
    local tty="${COPYBOOK_TTY:-/dev/tty}" ans
    if ! { : < "$tty"; } 2>/dev/null; then
      note "There is no terminal to ask in, so the new version replaces the old one."
      return 0
    fi
    exec 3< "$tty"
    printf '\n'
    say "What do you want to do with it?"
    note "1) Replace it with the new version      (press Enter)"
    note "2) Keep it, and install the new version next to it"
    while :; do
      printf '    Your choice [1/2]: '
      if ! IFS= read -r ans <&3; then printf '\n'; CHOICE=replace; break; fi
      case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
        ""|1|r|replace) CHOICE=replace; break ;;
        2|k|keep)       CHOICE=keep; break ;;
        *) note "Press Enter to replace, or type 2 to keep." ;;
      esac
    done
    exec 3<&-
    printf '\n'
  }

  local KEEP_OLD=0
  if [ "$HAVE_SELF" = 1 ] || [ -s "$DUPES" ]; then
    local CHOICE="$MODE"
    if [ "$CHOICE" = ask ]; then ask_keep_or_replace; fi
    if [ "$CHOICE" = keep ]; then
      # The old one stays exactly as it is. The new one goes in beside it under a free name.
      KEEP_OLD=1; CLEANUP=0
      if [ "$HAVE_SELF" = 1 ]; then
        local n=2
        while [ -e "$DEST_DIR/Copybook $n.app" ] || [ -L "$DEST_DIR/Copybook $n.app" ]; do n=$((n+1)); done
        DEST="$DEST_DIR/Copybook $n.app"
        DEST_REAL="$(real "$DEST" || echo "$DEST")"
        HAVE_SELF=0
        say "Keeping your current Copybook. The new version goes next to it as $(tilde "$DEST")."
      else
        say "Keeping the Copybook that is already here. The new version is installed next to it."
      fi
    fi
  fi

  # ---------- get the app ----------

  local SRC_APP=""

  build_from_source() {
    command -v swift >/dev/null 2>&1 || die "Building needs the Xcode Command Line Tools. Run  xcode-select --install  and try again."
    local dir
    if [ -f "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/Package.swift" ]; then
      dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # run from inside a clone
      say "Building from $dir"
    else
      say "Downloading the source ($REF)"
      curl -fsSL --proto '=https' --tlsv1.2 "https://github.com/$REPO/archive/$REF.tar.gz" -o "$WORK/src.tar.gz" \
        || die "Couldn't download the source from github.com/$REPO."
      mkdir "$WORK/src" && tar -xzf "$WORK/src.tar.gz" -C "$WORK/src" --strip-components 1
      dir="$WORK/src"
      say "Building (this takes a minute or two)"
    fi
    (cd "$dir" && ./build.sh) >"$WORK/build.log" 2>&1 || { tail -n 25 "$WORK/build.log" >&2; die "The build failed (log above)."; }
    SRC_APP="$dir/build/$APP_NAME"
    [ -d "$SRC_APP" ] || die "The build finished but produced no app."
  }

  download_release() {
    local base zip="$WORK/Copybook.zip" url sum_url
    # The built app is stored in the repository, in dist/. "latest" is the newest on the main branch;
    # a version is read from the tag v<version>.
    if [ "$VERSION" = "latest" ]; then base="https://github.com/$REPO/raw/main/dist"
    else base="https://github.com/$REPO/raw/v$VERSION/dist"; fi
    url="${COPYBOOK_ZIP_URL:-$base/Copybook.zip}"
    sum_url="${COPYBOOK_ZIP_URL:+$COPYBOOK_ZIP_URL.sha256}"; sum_url="${sum_url:-$base/Copybook.zip.sha256}"

    say "Downloading Copybook ($VERSION)"
    local proto="=https"; case "$url" in file://*) proto="=https,file" ;; esac
    curl -fL --proto "$proto" --tlsv1.2 --progress-bar "$url" -o "$zip" \
      || { rm -f "$zip"; return 1; }

    # Verify against the checksum published next to the download.
    if curl -fsSL --proto "$proto" --tlsv1.2 "$sum_url" -o "$WORK/Copybook.zip.sha256" 2>/dev/null; then
      local want got
      want="$(awk '{print $1}' "$WORK/Copybook.zip.sha256" | head -n 1)"
      got="$(shasum -a 256 "$zip" | awk '{print $1}')"
      [ -n "$want" ] && [ "$want" = "$got" ] || die "The download doesn't match its checksum, so it was not installed."
      note "Checksum OK"
    else
      die "Couldn't fetch the checksum, so the download was not installed."
    fi

    mkdir "$WORK/unzipped"
    ditto -x -k "$zip" "$WORK/unzipped" || die "Couldn't unpack the download."
    SRC_APP="$WORK/unzipped/$APP_NAME"
    [ -d "$SRC_APP" ] || die "The download doesn't contain $APP_NAME."
  }

  if [ "$BUILD" = 1 ]; then
    build_from_source
  else
    download_release || { note "No prebuilt app available; building from source instead."; build_from_source; }
    # A release built for Apple silicon only can't run on an Intel Mac: build for this one instead.
    local have; have="$(lipo -archs "$SRC_APP/Contents/MacOS/Copybook" 2>/dev/null || true)"
    case " $have " in *" $(uname -m) "*) ;; *)
      note "This release was built for: $have. This Mac is $(uname -m), so building from source."
      build_from_source ;;
    esac
  fi

  # Make sure it really is Copybook, and intact, before it replaces anything.
  [ "$(bundle_id "$SRC_APP")" = "$BUNDLE_ID" ] || die "That isn't the Copybook app, so it was not installed."
  codesign --verify --deep "$SRC_APP" 2>/dev/null || die "The app's signature is broken, so it was not installed."
  local NEW_VER; NEW_VER="$(bundle_ver "$SRC_APP")"

  # ---------- put it in place ----------

  # Same program already installed? Then there is nothing to swap, only the follow-up steps to make sure of.
  local SAME=0
  if [ "$HAVE_SELF" = 1 ] && [ -f "$DEST/Contents/MacOS/Copybook" ]; then
    if [ "$(shasum -a 256 < "$DEST/Contents/MacOS/Copybook")" = "$(shasum -a 256 < "$SRC_APP/Contents/MacOS/Copybook")" ] \
       && [ "$(bundle_ver "$DEST")" = "$NEW_VER" ]; then SAME=1; fi
  fi

  if [ "$SAME" = 1 ]; then
    say "Copybook $NEW_VER is already installed at $(tilde "$DEST")"
  else
    quit_all
    say "Installing Copybook $NEW_VER to $(tilde "$DEST")"
    local STAGING="$DEST_DIR/.Copybook-installing.$$" BACKUP=""
    rm -rf "$STAGING"
    ditto "$SRC_APP" "$STAGING" || { rm -rf "$STAGING"; die "Couldn't copy the app into $(tilde "$DEST_DIR") (disk full or no permission). Nothing was changed."; }
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
      BACKUP="$DEST_DIR/.Copybook-previous.$$"
      if ! mv "$DEST" "$BACKUP" 2>/dev/null; then
        rm -rf "$STAGING"
        die "Couldn't replace $(tilde "$DEST") (it belongs to another user or is locked). Remove it with:  sudo rm -rf '$DEST'  and run this again."
      fi
    fi
    if ! mv "$STAGING" "$DEST"; then
      if [ -n "$BACKUP" ]; then mv "$BACKUP" "$DEST"; fi       # put the previous version back
      rm -rf "$STAGING"
      die "Couldn't finish installing. The previous version, if there was one, was put back."
    fi
    if [ -n "$BACKUP" ]; then rm -rf "$BACKUP" 2>/dev/null || true; fi
  fi

  # The step that lets macOS open an app that isn't from the App Store or an identified developer.
  say "Allowing macOS to open it (removing the download quarantine mark)"
  note "xattr -dr com.apple.quarantine $DEST"
  xattr -dr com.apple.quarantine "$DEST"

  # Only now, with the new copy safely in place, remove the older duplicates.
  if [ "$CLEANUP" = 1 ] && [ -s "$DUPES" ]; then
    say "Removing older copies so there is only one Copybook"
    quit_all
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      remove_copy "$p" || true
    done < "$DUPES"
  fi
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

  say "Installed Copybook $(bundle_ver "$DEST")"
  note "Your clips and settings were kept."
  if [ "$KEEP_OLD" = 1 ]; then
    note "Your previous Copybook was kept too. Both copies use the same clips and settings, and Copybook runs only one copy at a time."
  fi
  if [ "$OPEN" = 1 ]; then
    open "$DEST"
    note "Opened. A short setup walks you through the shortcut and the Accessibility permission."
  fi
  if [ "$FAILED_REMOVALS" != 0 ]; then warn "Some older copies couldn't be removed (see above); everything else is done."; fi
  return 0
}

main "$@"
