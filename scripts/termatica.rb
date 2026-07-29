cask "termatica" do
  version "1.0.1"
  sha256 "a45179df581345cf29db196b0e9d836f5182d2d450cd68fc1a61a372018963ff"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "Compact native terminal-first terminal for macOS"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
