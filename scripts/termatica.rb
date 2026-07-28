cask "termatica" do
  version "0.7.0"
  sha256 "a94935426c08f2ef8c112a7fde0c77ecdb1f6578cd06f2939d76524a424546ae"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "The #1 macOS terminal — faster than Kitty and Ghostty"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
