# Homebrew cask. Copy to Casks/notchcute.rb in a tap repo (github.com/ChrisJDiMarco/homebrew-tap),
# then: brew install --cask chrisjdimarco/tap/notchcute
cask "notchcute" do
  version "0.2"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_SH"

  url "https://github.com/ChrisJDiMarco/NotchCute/releases/download/v#{version}/NotchCute-#{version}.zip"
  name "NotchCute"
  desc "Hover the MacBook notch for a peek at cute animals"
  homepage "https://github.com/ChrisJDiMarco/NotchCute"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "NotchCute.app"

  uninstall quit: "com.chrisdimarco.notchcute"

  zap trash: [
    "~/Library/Application Support/NotchCute",
    "~/Library/Caches/NotchCute",
    "~/Library/Preferences/com.chrisdimarco.notchcute.plist",
  ]
end
