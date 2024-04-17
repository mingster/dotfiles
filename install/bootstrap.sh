#!/usr/bin/env bash

echo 'bootstrap install dotfiles to your HOME directory...'

cd "$(dirname "${BASH_SOURCE}")";

git pull origin master;

function doIt() {
	rsync --exclude ".git/" --exclude ".DS_Store" --exclude "bootstrap.sh" \
		--exclude "README.md" --exclude "LICENSE-MIT.txt" -avh --no-perms .. ~;
	source ~/.bash_profile;
}

function doIt2() {
	ln -s ../.zshrc $HOME/
	ln -s ../.aliases $HOME/
	ln -s ../.bash_aliases $HOME/
	ln -s ../.bashrc $HOME/
	ln -s ../.bash_profile $HOME/
	ln -s ../.extra $HOME/
	ln -s ../.editorconfig $HOME/
	ln -s ../.functions $HOME/
	ln -s ../.functions $HOME/
	ln -s ../.gitconfig $HOME/
	ln -s ../.gitignore $HOME/
	ln -s ../.gitignore_global $HOME/
	ln -s ../.gvimrc $HOME/
	ln -s ../.inputrc $HOME/
	ln -s ../.hgignore_global $HOME/
	ln -s ../.nanorc $HOME/
	ln -s ../.nanorc $HOME/
	ln -s ../.p10k.zsh $HOME/
	ln -s ../.profile $HOME/
	ln -s ../.wgetrc $HOME/
}

if [ "$1" == "--force" -o "$1" == "-f" ]; then
	doIt2;
else
	read -p "This may overwrite existing files in your home directory. Are you sure? (y/n) " -n 1;
	echo "";
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		doIt2;
	fi;
fi;
unset doIt;
