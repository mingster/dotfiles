#!/usr/bin/env bash


# symlinks
ln -s ~/GitHub/dotfiles $HOME/dotfiles
ln -s -f ~/GitHub/dotfiles/.editorconfig $HOME/.editorconfig
ln -s -f ~/GitHub/dotfiles/.gitattributes $HOME/.gitattributes
ln -s -f ~/GitHub/dotfiles/.gitconfig $HOME/.gitconfig
ln -s -f ~/GitHub/dotfiles/.gitflow_export $HOME/.gitflow_export
ln -s -f ~/GitHub/dotfiles/.gitignore $HOME/.gitignore
ln -s -f ~/GitHub/dotfiles/.gitignore_global $HOME/.gitignore_global
ln -s -f ~/GitHub/dotfiles/.hgignore_global $HOME/.hgignore_global
ln -s -f ~/GitHub/dotfiles/.nanorc $HOME/.nanorc

# if mac, run install_mac/brew.sh


# if debian, run install_deb/build_sys.sh
