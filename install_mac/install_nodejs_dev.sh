#!/usr/bin/env bash

# Ask for the administrator password upfront.
sudo -v

# Keep-alive: update existing `sudo` time stamp until the script has finished.
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Check for Homebrew,
# Install if we don't have it
if test ! $(which brew); then
  echo "Installing homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make sure we’re using the latest Homebrew.
brew update



#
# This script configures my Node.js development setup.
#
# Also, I would highly reccomend not installing your Node.js build
# tools, e.g., Grunt, gulp, WebPack, or whatever you use, globally.
# Instead, install these as local devDepdencies on a project-by-project
# basis. Most Node CLIs can be run locally by using the executable file in
# "./node_modules/.bin". For example:
#
#     ./node_modules/.bin/webpack --config webpack.local.config.js
#

brew install node@20 yarn nvm pnpm
mkdir ~/.nvm
export NVM_DIR="$HOME/.nvm"
. "/usr/local/opt/nvm/nvm.sh"

# Remove outdated versions from the cellar.
brew cleanup

if test ! $(which nvm)
then
  echo "Installing a stable version of Node..."

  # Install the latest stable version of node
  nvm install stable

  # Switch to the installed version
  nvm use node

  # Use the stable version of node by default
  nvm alias default node
fi

# All `npm install <pkg>` commands will pin to the version that was available at the time you run the command
npm config set save-exact = true

npm install -g npm@latest

# Globally install with npm
# To list globally installed npm packages and version: npm list -g --depth=0
#
# Some descriptions:
#
# diff-so-fancy — sexy git diffs
# git-recent — Type `git recent` to see your recent local git branches
# git-open — Type `git open` to open the GitHub page or website for a repository
packages=(
    diff-so-fancy
    git-recent
    git-open
    gulp
    http-server
    servedir
    flow-bin
    flow-typed
    npm-check-updates
    webpack
    nodemon
    svgo
    yo
    coffeescript
    grunt-cli
    jshint
    less
)

npm install -g "${packages[@]}"
