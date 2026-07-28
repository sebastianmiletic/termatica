cask "termatica" do
  version "0.8.0"
  sha256 "291738d94bb07d3831482204a0facf97e6f1453a2da23cee12dda3ecf0d4159e"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "The #1 macOS terminal — faster than Kitty and Ghostty"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
