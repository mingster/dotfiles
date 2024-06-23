#!/usr/bin/env bash
if [ ! -d $HOME/dotfiles ];
then
  echo 'create symlinks...'

  ln -s ~/GitHub/dotfiles $HOME/
  ln -s -f ~/dotfiles/.csvignore $HOME/
  ln -s -f ~/dotfiles/.editorconfig $HOME/
  ln -s -f ~/dotfiles/.gitattributes $HOME/

  #ln -s -f ~/dotfiles/.gitconfig $HOME/
  cp ~/dotfiles/.gitconfig $HOME/

  ln -s -f ~/dotfiles/.gitflow_export $HOME/
  ln -s -f ~/dotfiles/.gitignore $HOME/
  ln -s -f ~/dotfiles/.gitignore_global $HOME/
  ln -s -f ~/dotfiles/.hgignore_global $HOME/
  ln -s -f ~/dotfiles/.nanorc $HOME/

  git config --global core.excludesfile ~/dotfiles/.gitignore_global
  git config --global core.attributesfile ~/dotfiles/.gitattributes
fi

echo $OSTYPE

case "$OSTYPE" in
  #linux*)   bash ./arch/system_setup.sh ;;
  darwin*)  bash ./mac/system_setup.sh ;;
  msys*)    echo "windows" ;;
  solaris*) echo "solaris" ;;
  bsd*)     echo "bsd" ;;
  *)        echo "unknown" ;;
esac
