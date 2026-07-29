cask "termatica" do
  version "1.2.0"
  sha256 "3ace3ad8f7f709bfb2207137f2748ec3a632a977a5864f5a8c18ab59702120e6"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "Compact native terminal-first terminal for macOS"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
