#!/usr/bin/env bash
if [ ! -d $HOME/dotfiles ];
then
  echo 'create symlinks...'

  ln -s ~/GitHub/dotfiles $HOME/
  ln -s -f ~/dotfiles/.csvignore $HOME/
  ln -s -f ~/dotfiles/.editorconfig $HOME/
  ln -s -f ~/dotfiles/.gitattributes $HOME/

  architecture=$(uname -m)
  if [ "$architecture" == "arm64" ]; then
    cp ~/dotfiles/.gitconfig $HOME/

  elif [ "$architecture" == "x86_64" ]; then
    cp ~/dotfiles/.gitconfig-x64 $HOME/.gitconfig

  else
      echo "Unknown architecture: $architecture"
  fi

  ln -s -f ~/dotfiles/.gitflow_export $HOME/
  ln -s -f ~/dotfiles/.gitignore $HOME/
  ln -s -f ~/dotfiles/.gitignore_global $HOME/
  ln -s -f ~/dotfiles/.hgignore_global $HOME/
  ln -s -f ~/dotfiles/.nanorc $HOME/
  ln -s -f ~/dotfiles/.vimrc $HOME/
  ln -s -f ~/dotfiles/.vim $HOME/

  git config --global core.excludesfile ~/dotfiles/.gitignore_global
  git config --global core.attributesfile ~/dotfiles/.gitattributes
fi

set OSTYPE==$(uname -s)
#echo $OSTYPE

case "$OSTYPE" in
  #linux*)   bash ./arch/system_setup.sh ;;
  darwin*)  echo "mac install" ; bash ./mac/system_setup.sh ;;
  msys*)    echo "windows" ;;
  solaris*) echo "solaris" ;;
  bsd*)     echo "bsd" ;;
  *)        echo "unknown" ;;
esac
