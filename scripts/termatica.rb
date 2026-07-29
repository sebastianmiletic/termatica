cask "termatica" do
  version "1.2.0"
  sha256 "fe7a3caaf68fb3f5b34c41ef613d17963ffa8cb05102d86a778a1b04276248c1"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "Compact native terminal-first terminal for macOS"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
