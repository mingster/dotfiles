#!/usr/bin/env bash

echo 'install my brew apps...'

#brew install --cask --appdir="~/Applications" xquartz
brew install --cask --appdir="/Applications/Utilities" onyx
brew install --cask the-unarchiver

# Development tools
# brew install git
# brew install --cask virtualbox
# brew install --cask vagrant
# Install Docker, which requires virtualbox
#brew install docker
#brew install docker-compose
#brew install boot2docker
brew install nmap tmux

mkdir /Applications/_dev

#brew install --cask --appdir="/Applications/_dev" docker
brew install --cask --appdir="/Applications/_dev" github
#brew install --cask --appdir="/Applications/_dev" sourcetree
#brew install --cask --appdir="/Applications/_dev" staruml
brew install --cask --appdir="/Applications/_dev" visual-studio-code
brew install --cask --appdir="/Applications/_dev" cursor

# copy over visual-studio-code setting
cp ~/dotfiles/vscode/vscode-settings.json  ~/Library/Application\ Support/Code/User/settings.json

brew install --cask --appdir="/Applications/_dev" azure-data-studio
#brew install --cask --appdir="/Applications/_dev" 0xed
#brew install --cask --appdir="/Applications/_dev" eclipse-java
#brew install --cask --appdir="/Applications/_dev" eclipse-jee
#brew install --cask --appdir="/Applications/_dev" jd-gui
#brew install --cask --appdir="/Applications/_dev" dash

#brew install --appdir="/Applications/_dev" --cask blender
#brew install --appdir="/Applications/_dev" --cask db-browser-for-sqlite
#brew install --cask wireshark

brew install --cask --appdir="/Applications/Utilities" balenaetcher

#brew install oath-toolkit

# Misc casks
#brew install --cask aerial #appletv screen saver
#brew install --cask welly #ptt telnet client
#brew install --cask evernote
#brew install --cask raycast
#brew install --cask vnc-viewer
brew install --cask chatgpt
brew install --cask claude
brew install --cask notion
#brew install --cask obsidian
#brew install --cask gimp
#brew install --cask inkscape
#brew install --cask shottr
#brew install --cask cyberduck
brew install --cask telegram

#https://www.torproject.org/docs/tor-doc-osx.html.en
#brew install tor

brew install --cask google-drive
brew install --cask readdle-spark

brew install --cask tor-browser
brew install --cask brave-browser
brew install --cask firefox
#brew install --cask chromium
#brew install --cask arc

#brew install --cask libreoffice

#brew install --cask iterm2
#brew install --cask atom
#brew install --cask macdown
#brew install --cask teamviewer
#brew install --cask skype
#brew install --cask slack
#brew install --cask dropbox
#brew install --cask onedrive
brew install --cask megasync
#brew install --cask numi
#brew install --cask alfred
#brew install --cask keyboard-maestro
#1176895641  Spark – Email App by Readdle
#mas install 1176895641

#Remove comment to install LaTeX distribution MacTeX
#brew install --cask mactex

# Install av staff
mkdir /Applications/_av

brew install --cask --appdir="/Applications/_av" aegisub
brew install --cask --appdir="/Applications/_av" handbrake
brew install --cask --appdir="/Applications/_av" kid3
brew install --cask --appdir="/Applications/_av" jubler
brew install --cask --appdir="/Applications/_av" vox
brew install --cask --appdir="/Applications/_av" iina
brew install --cask --appdir="/Applications/_av" xld

#brew install --cask --appdir="/Applications/_av" get-lyrical
#brew install mp3splt

#ffmpeg with aac/mp4 support
# https://gist.github.com/clayton/6196167
brew install homebrew-ffmpeg/ffmpeg/ffmpeg

# replave obsoleted youtube-dl with yt-dlp
brew install yt-dlp
ln -s /usr/local/bin/yt-dlp /usr/local/bin/youtube-dl                                                                                                                                                                                                     1 ✘

#brew install libvpx
#brew install ffmpeg #--with-fdk-aac --with-tools --with-sdl2 --with-freetype --with-libass --with-libqavi --with-libvorbis --with-libvpx --with-opus --with-x265

# Install developer friendly quick look plugins; see https://github.com/sindresorhus/quick-look-plugins
#brew install --cask qlcolorcode qlstephen qlmarkdown quicklook-json qlprettypatch quicklook-csv betterzipql qlimagesize webpquicklook suspicious-package

# install packages listed in Brewfile
#### review Brewfile and manaully pick the app to install ###
#brew bundle

# Replace cli with gnu/linux
#./homebrew-install-gnu.sh

brew install --cask google-chrome@dev
#brew install --cask google-chrome-canary
brew install --cask safari-technology-preview

# https://github.com/ryanoasis/nerd-fonts/releases/download/v2.1.0/SourceCodePro.zip
#cd ~/Library/Fonts && curl -fLo "Sauce Code Pro Medium Nerd Font Complete.ttf" https://github.com/ryanoasis/nerd-fonts/blob/master/patched-fonts/SourceCodePro/Regular/complete/Sauce%20Code%20Pro%20Nerd%20Font%20Complete.ttf
#brew tap homebrew/cask-fonts && brew install --cask font-source-code-pro
#brew install --cask homebrew/cask-fonts/font-source-code-pro
#brew install --cask font-sourcecodepro-nerd-font

# xcode
# https://www.moncefbelyamani.com/how-to-install-xcode-with-homebrew/
mas search xcode

#497799835  Xcode                                               (16.3)
mas install 497799835

#line
mas install 539883307

#notebooklm
#mas install 6737527615

# non-automated
# vmware
# msoffice
