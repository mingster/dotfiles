#!/usr/bin/env bash

# requirement: asdf (check system_setup.sh for installation)
#brew install coreutils curl git
#brew install asdf
#git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0

echo '---- uninstall swift ----'

brew list | grep -iE 'swift'
for pkg in $(brew list | grep -iE 'swift'); do brew --ignore-dependencies uninstall $pkg; done

brew list | grep -iE 'swiftpm'
for pkg in $(brew list | grep -iE 'swiftpm'); do brew --ignore-dependencies uninstall $pkg; done

#brew search '/swift/' | awk '{print $1}' | xargs brew uninstall --cask
#brew search '/swiftpm/' | awk '{print $1}' | xargs brew uninstall --cask
