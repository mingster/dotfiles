#!/usr/bin/env bash

# requirement: asdf (check system_setup.sh for installation)
#brew install coreutils curl git
#brew install asdf
#git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0

echo '---- install node.js ----'

for pkg in $(brew list | grep -iE 'node'); do brew uninstall --ignore-dependencies "$pkg"; done

asdf plugin list 2>/dev/null | grep -q '^nodejs$' || asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git

asdf list all nodejs | wc -l

#asdf install nodejs 22.14.0
#asdf global nodejs 22.14.0
#asdf shell nodejs 22.14.0
#asdf set -u nodejs 22.14.0

asdf list nodejs 2>/dev/null | grep -q '24.15.0' || asdf install nodejs 24.15.0
asdf set -u nodejs 24.15.0

asdf plugin update --all

# install bun (skip if already present)
command -v bun >/dev/null 2>&1 || curl -fsSL https://bun.sh/install | bash
