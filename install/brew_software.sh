
#brew cask install --appdir="~/Applications" xquartz



#brew install git
#brew cask install virtualbox
#brew cask install vagrant
# Install Docker, which requires virtualbox
brew install docker
brew install boot2docker


brew cask install --appdir="/Applications/_dev" 0xed
brew cask install --appdir="/Applications/_dev" eclipse-jee
brew cask install --appdir="/Applications/_dev" jd-gui
brew cask install --appdir="/Applications/_dev" dash
brew cask install wireshark

# Misc casks
brew cask install aerial #appletv screen saver
brew cask install welly #ptt telnet client
#brew cask install evernote
#brew cask install 1password
#brew cask install gimp
#brew cask install inkscape
brew cask install skitch

#https://www.torproject.org/docs/tor-doc-osx.html.en
#brew install tor
brew cask install tor-browser

#Remove comment to install LaTeX distribution MacTeX
#brew cask install mactex

# Install av staff
mkdir /Applications/_av

brew cask install --appdir="/Applications/_av" aegisub
brew cask install --appdir="/Applications/_av" handbrake
brew cask install --appdir="/Applications/_av" kid3
brew cask install --appdir="/Applications/_av" jubler
brew cask install --appdir="/Applications/_av" vox
brew cask install --appdir="/Applications/_av" iina
brew cask install --appdir="/Applications/_av" xld
#brew cask install --appdir="/Applications/_av" get-lyrical
brew install mp3splt

#ffmpeg with aac/mp4 support
# https://gist.github.com/clayton/6196167
brew install libvpx
brew install ffmpeg --with-fdk-aac --with-tools --with-sdl2 --with-freetype --with-libass --with-libqavi --with-libvorbis --with-libvpx --with-opus --with-x265

# Install developer friendly quick look plugins; see https://github.com/sindresorhus/quick-look-plugins
#brew cask install qlcolorcode qlstephen qlmarkdown quicklook-json qlprettypatch quicklook-csv betterzipql qlimagesize webpquicklook suspicious-package

# install packages listed in Brewfile
#### review Brewfile and manaully pick the app to install ###
#brew bundle

# Replace cli with gnu/linux
#./homebrew-install-gnu.sh


#google-chrome-canary
brew tap homebrew/cask-versions
brew cask install google-chrome-canary