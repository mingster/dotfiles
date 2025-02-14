#!/bin/sh

fetch(){
    echo "Removing brew cache"
    rm -rf "$(brew --cache)"
    echo "Running brew update"
    brew update
}

lookup() {
  for c in $(brew list --cask); do
    brew info --cask $c
  done
}

update_cask(){
  var=$( lookup  | grep -B 3 'Not installed' | sed -e '/^http/d;/^Not/d;/:/!d'  | cut -d ":" -f1)
  if [ -n "$var" ]; then
  echo "The following installed casks have updates avilable:"
  echo "$var"
  echo "Install updates now?"
  select yn in "Yes" "No"; do
    case $yn in
      "Yes") echo "updating outdated casks"; break;;
      "No") echo "brew cask upgrade cancelled" ;return;;
      *) echo "Please choose 1 or 2";;
    esac
    done
  for i in $var; do
    echo "Uninstalling $c"; brew uninstall --cask --force "$i"; echo "Re-installing $i"; brew install --cask "$i"
  done
else
  echo "all casks are up to date"
fi
}

fetch
update_cask
