# Homebrew Cask formula for Clyde.
#
# This file is the canonical source of the cask. To make `brew install
# --cask clyde` work for users, copy it into your own homebrew tap repo
# (e.g. github.com/kl0sin/homebrew-tap/Casks/clyde.rb), then users
# can:
#
#     brew tap kl0sin/tap
#     brew install --cask clyde
#
# The version + sha256 are updated automatically by the release workflow
# (see .github/workflows/release.yml — TODO step) once the GitHub Release
# has been published. Until then, run `scripts/release/update-cask.sh`
# locally.

cask "clyde" do
  version "0.1.0"
  sha256 "REPLACE_ME_WITH_DMG_SHA256"

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
