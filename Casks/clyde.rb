# Canonical Homebrew cask for Clyde.
#
# This file is the source of truth. On every signed release, the
# release workflow runs scripts/release/update-cask.sh to stamp in the
# new version + DMG sha256 and pushes the result to
# https://github.com/kl0sin/homebrew-tap so users can
#
#     brew tap kl0sin/tap
#     brew install --cask clyde
#
# To bump by hand, run:
#     scripts/release/update-cask.sh path/to/Clyde-x.y.z.dmg
#
# The script rewrites the `version "..."` and `sha256 "..."` lines in
# place — keep their format intact.

cask "clyde" do
  version "0.4.0"
  sha256 "2db896ddd1caf2c231595a7d786429633b6843510c923d4b4b06cbcbd6ba4dc4"

  url "https://github.com/kl0sin/clyde/releases/download/v#{version}/Clyde-#{version}.dmg"
  name "Clyde"
  desc "Friendly Claude Code session monitor that lives in the macOS menu bar"
  homepage "https://kl0sin.github.io/clyde/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true   # Sparkle handles auto-updates inside the app

  depends_on macos: ">= :ventura"

  app "Clyde.app"

  zap trash: [
    "~/.clyde",
    "~/Library/Preferences/io.github.kl0sin.clyde.plist",
    "~/Library/Application Support/Clyde",
    "~/Library/Caches/io.github.kl0sin.clyde",
  ]
end
