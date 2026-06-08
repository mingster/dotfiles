#!/usr/bin/env bash

# Helper: install a formula only if not already present
bi() { brew list "$1" >/dev/null 2>&1 || brew install "$1"; }
# Helper: install a cask only if not already present
bc() { brew list --cask "$1" >/dev/null 2>&1 || brew install --cask "${@}"; }

echo ""
echo -e "\033[1;35m cli apps \033[0m"
echo ""


echo ""
echo -e "\033[1;35m Essential apps \033[0m"
echo ""

# Misc casks
#bc aerial        # appletv screen saver
#bc welly         # ptt telnet client
#bc evernote
bc raycast
bc vnc-viewer
#bc chatgpt

bc claude
command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash

bc google-chrome
bc megasync
bc notion
bc obsidian
bc zed

#bc gimp
#bc inkscape
#bc shottr
#bc cyberduck
bc telegram
bc whatsapp
#bc raycast #use buit-in spotlight instead

# remote deskop
bc windows-app

#https://www.torproject.org/docs/tor-doc-osx.html.en
#bi tor

bc google-drive
bc readdle-spark
bc tor-browser
bc brave-browser
bc firefox
#bc chromium
#bc arc

#bc libreoffice
#bc iterm2
#bc atom
#bc macdown
#bc teamviewer
#bc skype
#bc slack
#bc dropbox
#bc onedrive
#bc numi
#bc alfred
#bc keyboard-maestro
#1176895641  Spark – Email App by Readdle
#mas list | grep -q '^1176895641' || mas install 1176895641

#Remove comment to install LaTeX distribution MacTeX
#bc mactex
#bc --appdir="~/Applications" xquartz

brew list --cask onyx         >/dev/null 2>&1 || brew install --cask --appdir="/Applications/Utilities" onyx
brew list --cask balenaetcher >/dev/null 2>&1 || brew install --cask --appdir="/Applications/Utilities" balenaetcher
bc the-unarchiver

echo ""
echo -e "\033[1;35m development apps \033[0m"
echo ""

mkdir -p /Applications/_dev

#brew list --cask dcocker        >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" docker
brew list --cask github        >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" github
#brew list --cask sourcetree   >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" sourcetree
#brew list --cask staruml      >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" staruml
brew list --cask antigravity   >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" antigravity
brew list --cask antigravity-ide   >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" antigravity-ide
brew list --cask visual-studio-code >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" visual-studio-code
#brew list --cask azure-data-studio >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" azure-data-studio
#brew list --cask blender           >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" blender
#bc wireshark

echo ""
echo -e "\033[1;35m video/ audio apps \033[0m"
echo ""

mkdir -p /Applications/_av

brew list --cask aegisub  >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_av" aegisub
brew list --cask handbrake >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_av" handbrake
brew list --cask kid3     >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_av" kid3
brew list --cask jubler   >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_av" jubler
brew list --cask vox      >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_av" vox
brew list --cask iina     >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_av" iina
brew list --cask xld      >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_av" xld

#bc --appdir="/Applications/_av" get-lyrical
#bi mp3splt

# replace obsoleted youtube-dl with yt-dlp
# yt-dlp_macos is a universal binary (arm64 + x86_64); download directly instead of brew
if ! command -v yt-dlp >/dev/null 2>&1; then
  curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o /usr/local/bin/yt-dlp
  chmod +x /usr/local/bin/yt-dlp
fi
[ -e /usr/local/bin/youtube-dl ] || ln -s /usr/local/bin/yt-dlp /usr/local/bin/youtube-dl

#bi ffmpeg

# Install developer friendly quick look plugins; see https://github.com/sindresorhus/quick-look-plugins
#bc qlcolorcode qlstephen qlmarkdown quicklook-json qlprettypatch quicklook-csv betterzipql qlimagesize webpquicklook suspicious-package

bc google-chrome@dev
#bc google-chrome-canary
#bc safari-technology-preview

# browsh
#brew tap browsh-org/homebrew-browsh && bi browsh

# gemini cli
command -v gemini >/dev/null 2>&1 || npx https://github.com/google-gemini/gemini-cli

# xcode
# https://www.moncefbelyamani.com/how-to-install-xcode-with-homebrew/
mas list | grep -q '^497799835' || mas install 497799835  # Xcode
mas list | grep -q '^539883307' || mas install 539883307  # Line

#mas list | grep -q '^6737527615' || mas install 6737527615  # NotebookLM

# non-automated
# vmware #https://support.broadcom.com/group/ecx/productdownloads?subfamily=VMware%20Fusion&freeDownloads=true
# msoffice
