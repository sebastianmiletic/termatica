cask "termatica" do
  version "1.1.0"
  sha256 "dc3cdab474d5fe64f89bf43c4835966a9b6fbe073e887f9f0a53cc3ef16afafa"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "Compact native terminal-first terminal for macOS"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
