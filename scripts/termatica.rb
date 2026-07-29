cask "termatica" do
  version "1.0.2"
  sha256 "2ee6778500b8e6a0764caf44bd83935d23f539377e8eea299c21f286cd420192"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "Compact native terminal-first terminal for macOS"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
