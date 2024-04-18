#!/usr/bin/env bash

brew tap homebrew/dupes

# Install `wget` with IRI support.
brew install wget --with-iri

# Install more recent versions of some OS X tools.
brew install vim --override-system-vi

# see https://www.topbug.net/blog/2013/04/14/install-and-use-gnu-command-line-tools-in-mac-os-x/

# core
brew install coreutils
brew install binutils
brew install diffutils

# key commands
brew install binutils
brew install diffutils
brew install ed --default-names
brew install findutils --with-default-names
brew install gawk
brew install gnu-indent --with-default-names
brew install gnu-sed --with-default-names
brew install gnu-tar --with-default-names
brew install gnu-which --with-default-names
brew install gnutls
brew install grep --with-default-names
brew install gzip
brew install screen
brew install watch
brew install wdiff --with-gettext
brew install telnet

# OS X ships a GNU version, but too old
brew install bash
brew install emacs
brew install gdb  # gdb requires further actions to make it work. See `brew info gdb`.
brew install gpatch
brew install m4
brew install make
brew install nano

# Other commands (non-GNU)
brew install file-formula
brew install git
brew install less
brew install openssh
brew install perl518   # must run "brew tap homebrew/versions" first!
brew install python
brew install rsync
brew install svn
brew install unzip
brew install vim --override-system-vi
#brew install macvim --override-system-vim --custom-system-icons
brew install zsh

# Remove outdated versions from the cellar.
brew cleanup

# check
brew doctor
