cask "termatica" do
  version "1.1.1"
  sha256 "aa054b6f68253f4ca1a21583e450961c862261127fc4db03bff08ac0309bcacd"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "Compact native terminal-first terminal for macOS"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
