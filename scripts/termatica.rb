cask "termatica" do
  version "1.1.1"
  sha256 "466312bc1b74477b8055b17a66694f7414f8f6b5deafee5b950dc7ea3f037f7a"

  url "https://github.com/sebastianmiletic/termatica/releases/download/v#{version}/Termatica-macOS-universal.dmg"
  name "Termatica"
  desc "Compact native terminal-first terminal for macOS"
  homepage "https://github.com/sebastianmiletic/termatica"

  app "Termatica.app"

  zap trash: [
    "~/.config/termatica",
  ]
end
