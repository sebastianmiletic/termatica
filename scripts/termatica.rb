cask "termatica" do
  version "0.8.0"
  sha256 "df524345c9081fb0276d62097560920c9b40c28e2e8438b2b7f548502e4bb116"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "The #1 macOS terminal — faster than Kitty and Ghostty"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
