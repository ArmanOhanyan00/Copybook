# Copybook

Copybook is a free clipboard manager for macOS. It keeps everything you copy, lets you search it, and lets you
paste any of it again with one click.

Copybook is an independent open-source project, written from scratch in Swift and SwiftUI. It is not affiliated
with any other clipboard app or company. Everything it stores stays on your Mac.

## Install

Pick one command and run it in Terminal. Each one installs Copybook and then runs the command that lets
macOS open it (explained below).

**Homebrew**

```bash
brew tap ArmanOhanyan00/copybook https://github.com/ArmanOhanyan00/Copybook && brew install --cask ArmanOhanyan00/copybook/copybook
```

**npm**

```bash
npm install -g --allow-scripts=copybook-mac https://github.com/ArmanOhanyan00/Copybook/tarball/main
```

Installing this package runs the installer automatically. `--allow-scripts=copybook-mac` tells npm that this one
package may run its install step. Newer npm versions block install steps unless you allow them, and without the
flag npm 11 prints a warning. If npm still did not install the app, run `copybook-mac` once and it does.

The short form `npm install -g ArmanOhanyan00/Copybook` does not work with npm 11, so use the link above.

**curl**

```bash
curl -fsSL https://raw.githubusercontent.com/ArmanOhanyan00/Copybook/main/install.sh | bash
```

You can read the script before you run it: [install.sh](install.sh).

Other ways to run the same script:

```bash
wget -qO- https://raw.githubusercontent.com/ArmanOhanyan00/Copybook/main/install.sh | bash
bash <(curl -fsSL https://raw.githubusercontent.com/ArmanOhanyan00/Copybook/main/install.sh)
git clone https://github.com/ArmanOhanyan00/Copybook.git && cd Copybook && ./install.sh --build
```

The last one builds the app on your Mac instead of downloading it. It needs the Xcode Command Line Tools
(`xcode-select --install`).

### What the install does

1. It looks for a Copybook that is already on your Mac.
2. If it finds one, it tells you which one and asks what to do:
   - Press **Enter** to **replace** it with the new version.
   - Type **2** and press Enter to **keep** the old one. The old one stays exactly as it is, and the new
     version is installed next to it as `Copybook 2.app`.
3. It downloads the app (the app file is stored in this repository, in the `dist` folder) and checks it
   against its SHA-256 checksum.
4. It puts `Copybook.app` in `/Applications`. If your account cannot write to `/Applications`, it uses
   `~/Applications` instead. The old version stays in place until the new one is fully copied.
5. It runs this command:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Copybook.app
   ```

   macOS refuses to open an app that was downloaded from the internet unless Apple has approved its developer.
   Copybook is free and is not signed with a paid Apple Developer ID, so macOS would show "Copybook can't be
   opened". The command removes the "downloaded from the internet" mark from `Copybook.app`, and from nothing else.
6. If you chose to replace, it removes the other copies of Copybook in your Applications folders, so that
   only the new one is left. If you chose to keep, it removes nothing.
7. It opens Copybook.

Your clips and settings are never deleted by an install, an update, or a removal of the app.

The question in step 2 is asked only when Terminal can ask it. Run from a script with no terminal, the
installer replaces the old version without asking. To skip the question yourself, add `--replace` or `--keep`.

If you keep the old copy, both copies use the same clips and settings, and Copybook runs only one copy at a
time. Quit one before opening the other.

### Homebrew notes

- The Homebrew command has two parts joined by `&&`. The first part (`brew tap`) tells Homebrew where
  Copybook's install recipe is: this repository. The second part installs Copybook.
- `brew install copybook` (the short form) does not work. The short form is only for apps in Homebrew's own
  list, and Copybook is not in it.
- Homebrew cannot ask questions. If a Copybook is already in `/Applications` from another install method,
  Homebrew stops and tells you. Add `--force` to the second part to replace it:
  `brew install --cask --force ArmanOhanyan00/copybook/copybook`.

### Update

| You installed with | Run |
| --- | --- |
| Homebrew | `brew upgrade --cask copybook` |
| npm | the same npm command again |
| curl | the same curl command again |

### Remove the app

| You installed with | Run |
| --- | --- |
| Homebrew | `brew uninstall --cask copybook` |
| npm | `copybook-mac --uninstall`, then `npm uninstall -g copybook-mac` |
| curl | `curl -fsSL https://raw.githubusercontent.com/ArmanOhanyan00/Copybook/main/install.sh \| bash -s -- --uninstall` |

Removing the app keeps your clips. To delete the app and all of its data in one step, open
Copybook › Settings › About › **Delete Everything…**.

### Installer options

Put the option after the command. With curl, put it after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/ArmanOhanyan00/Copybook/main/install.sh | bash -s -- --version 1.0
```

| Option | What it does |
| --- | --- |
| `--version 1.0` | Installs that version instead of the newest. |
| `--replace` | Replaces a previous Copybook without asking. |
| `--keep` | Keeps a previous Copybook without asking, and installs the new version next to it. |
| `--user` | Installs to `~/Applications` instead of `/Applications`. |
| `--build` | Builds the app from the source code instead of downloading it. |
| `--no-cleanup` | Does not remove other copies of Copybook. |
| `--no-open` | Does not open Copybook when it is done. |
| `--dry-run` | Shows what would happen and changes nothing. |
| `--uninstall` | Quits Copybook and removes every copy of the app. Your clips stay. |

### Which other copies the installer removes

This applies when you choose to replace. The installer recognises Copybook by its built-in identity, not by its file name, so a renamed copy
(for example `Copybook 2.app`) is found too. After the new version is in place it removes the other copies
that are in `/Applications`, in `~/Applications`, or in a place where an earlier Copybook recorded that it ran.
It never touches these, and it tells you where they are: a copy in Downloads or on a disk image, a build
folder inside a source-code checkout, Homebrew's own backup, a copy in the Trash, and any other app that merely
has the name Copybook. If a copy cannot be deleted, the installer prints the exact command that removes it.

## Requirements

- macOS 14 or later.
- The download contains the app for Apple silicon Macs and for Intel Macs.
- The Liquid Glass look needs macOS 26.

## Using Copybook

The first time Copybook opens, a short setup explains the Accessibility permission and lets you choose your
shortcuts and layout. Each step is saved as you go. If you quit in the middle, it continues from where you
stopped. You can skip it, and you can run it again from Settings › About.

1. Press **⇧⌘V** to open Copybook. You can change this shortcut in Settings › Shortcuts.
2. **Click** a clip to copy it. **Double-click** it to paste it into the app you are typing in. **Drag** it
   to drop it anywhere.
3. To paste into other apps, allow Copybook under System Settings › Privacy & Security › Accessibility.
   Without that permission, Copybook still copies the clip, and you press ⌘V yourself.

### Features

- **History** of text, rich text, links, images, colours and files, grouped by day, with the icon of the app
  each clip came from.
- **Search** by content, app or type. Search also finds text inside images (it reads them on your Mac).
- **Two layouts:** a horizontal bar along the bottom of the screen, or a tall panel on the right edge.
- **Cards or a list**, chosen in Settings. For cards you choose the shape: Square, Landscape (4:3),
  Wide (16:9), Portrait (3:4), Tall (9:16), or Auto. A card keeps its shape when you resize the panel. In the
  vertical panel, cards sit side by side when there is room. The list shows one compact row per clip.
- **Move and resize** the panel freely. After you move or resize it, Copybook asks whether to keep that
  size and position.
- **Pin** keeps the panel open, at the same place and size, until you unpin it.
- **Stack** collects several clips so you can paste them one after another with ⌘V. Open it with **⇧⌘C**.
- **Colour picker** (**⌃⇧⌘C**) picks any colour on your screen, copies it and saves it to the history.
- **Preview** a clip, **edit** a text clip, **rename** a clip, **paste as plain text**.

### Keys in the panel

| Key | Action |
| --- | --- |
| ← → ↑ ↓ | Move between clips |
| ↩ | Paste |
| ⇧↩ | Paste as plain text |
| ⌘1 – ⌘9 | Paste the 1st to 9th clip |
| Space | Preview |
| ⌘C | Copy |
| ⌘E | Edit |
| ⌘⌫ | Delete |
| ⌘F, or just start typing | Search |
| ⎋ | Close |

## Privacy and data

- Your history is stored in `~/Library/Application Support/Copybook/`. It never leaves your Mac.
- Copybook ignores items that apps mark as concealed or transient (the nspasteboard.org convention), and the
  apps you list in Settings › Privacy.
- When you copy a link, Copybook can fetch that page's title and picture from the linked site. Turn this off
  in Settings › Privacy › Link previews.
- Copybook can hide itself from screenshots and screen sharing. This is a setting in Settings › Privacy.

### Where Copybook keeps things

Settings › About lists every place Copybook stores anything (clips, settings, caches, temporary files and each
copy of the app) with its size. **Delete Everything…** removes all of it: those files, the login item, the
Accessibility permission and the app itself. It deletes only items that have Copybook's own names, in the
folders where Copybook puts them. It checks that an app really is Copybook before removing it. It asks first,
with Cancel as the default answer. Deleting cannot be undone.

## Build from source

You need the Xcode Command Line Tools.

```bash
./build.sh                          # builds build/Copybook.app
./build.sh --install                # also copies it to ~/Applications and opens it
COPYBOOK_UNIVERSAL=1 ./build.sh     # one app for both Apple silicon and Intel
```

With only the Command Line Tools installed, the script builds against the macOS 26 SDK. The app is signed
ad hoc with a fixed designated requirement, so macOS keeps its Accessibility permission when you rebuild.

## Development and tests

- `COPYBOOK_SELFTEST=<folder>` renders the panel and Settings to pictures and clicks through them.
- `COPYBOOK_LAYOUTTEST=<folder>` checks both layouts, spacing and stress cases.
- `COPYBOOK_PINTEST=size|pin|level|style` checks resizing, pinning, window levels, and the card shapes and list.
- `COPYBOOK_FOOTPRINTTEST=<folder>` runs "Delete Everything" against a made-up home folder, never your real one.
- `COPYBOOK_SETUPTEST=<stage>` walks through the setup and its resume after a restart.
- `Support/test-install.sh` runs the installer through every situation it handles, against made-up folders.

Set `COPYBOOK_TEST_DEFAULTS=1` so that test runs use their own settings. To keep a test run away from your real
clips, also set `COPYBOOK_DATA_DIR` to a copy of the data folder. The tests that use the mouse need the screen
unlocked.

## Making a release

```bash
./make-release.sh
git add -A
git commit -m "Copybook 1.1"
git tag v1.1
git push
git push --tags
```

`./make-release.sh` builds one app for both Apple silicon and Intel and writes `dist/Copybook.zip` and
`dist/Copybook.zip.sha256`. It also writes the new version and checksum into `Casks/copybook.rb`,
`package.json`. The installer downloads the app from the `dist` folder of this repository, so no separate
GitHub release is needed. The tag must be `v` plus the version number in `Support/Info.plist`. Homebrew reads
the app from that tag.

## Licence

MIT. See [LICENSE](LICENSE).
