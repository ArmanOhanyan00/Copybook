cask "copybook" do
  version "1.0"
  sha256 "90d14c3f2ab238a79112a041bab7c39ecafabcef88e895bf2de25bfc6d56e99b"

  url "https://github.com/ArmanOhanyan00/Copybook/raw/v#{version}/dist/Copybook.zip"
  name "Copybook"
  desc "Clipboard manager"
  homepage "https://github.com/ArmanOhanyan00/Copybook"

  depends_on macos: :sonoma

  app "Copybook.app"

  # An older Copybook in ~/Applications (for example from building it yourself) would otherwise sit
  # next to this one as a duplicate. It is removed only if it really is Copybook.
  preflight_steps do
    terminate_process "Copybook"
    run "/bin/sh",
        args:           ["-c",
                         'p="$HOME/Applications/Copybook.app"; ' \
                         'plist="$p/Contents/Info.plist"; ' \
                         '[ -d "$p" ] && [ ! -L "$p" ] && ' \
                         'id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null)" && ' \
                         '[ "$id" = "local.copybook.app" ] && /bin/rm -rf "$p"; exit 0'],
        writable_paths: ["Applications/Copybook.app"],
        writable_base:  :home
  end

  # Copybook isn't signed with a paid Apple Developer ID, so macOS would refuse to open a
  # downloaded copy. This clears the download mark on Copybook.app only.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Copybook.app"],
        writable_paths: ["Copybook.app"],
        writable_base:  :appdir
  end

  uninstall quit: "local.copybook.app"

  zap trash: [
    "~/Library/Application Support/Copybook",
    "~/Library/Caches/local.copybook.app",
    "~/Library/HTTPStorages/local.copybook.app",
    "~/Library/Preferences/local.copybook.app.plist",
    "~/Library/Saved Application State/local.copybook.app.savedState",
  ]
end
