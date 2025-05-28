#!/bin/bash

# execute command
# -------------------
# curl -s https://raw.githubusercontent.com/mingster/dotfiles/master/vscode/install-vscode-extensions.sh | /bin/bash

# Visual Studio Code :: Package list
# get this list by: code --list-extensions
pkglist=(
anteprimorac.html-end-tag-labels
benjaminbenais.copilot-theme
biomejs.biome
bradlc.vscode-tailwindcss
cesium.gltf-vscode
christian-kohler.npm-intellisense
christian-kohler.path-intellisense
ckolkman.vscode-postgres
codezombiech.gitignore
davidanson.vscode-markdownlint
donjayamanne.githistory
dotjoshjohnson.xml
editorconfig.editorconfig
esbenp.prettier-vscode
exodiusstudios.comment-anchors
formulahendry.auto-close-tag
formulahendry.auto-rename-tag
foxundermoon.shell-format
github.codespaces
github.copilot
github.copilot-chat
github.github-vscode-theme
github.remotehub
heybourn.headwind
jasonnutter.search-node-modules
josee9988.minifyall
maptz.regionfolder
mikestead.dotenv
mrmlnc.vscode-scss
ms-vscode.remote-repositories
pkief.material-icon-theme
pkief.material-product-icons
planbcoding.vscode-react-refactor
prisma.prisma
redhat.vscode-xml
richie5um2.vscode-sort-json
s-nlf-fh.glassit
sburg.vscode-javascript-booster
shd101wyy.markdown-preview-enhanced
sibiraj-s.vscode-scss-formatter
usernamehw.errorlens
vsls-contrib.gistfs
yoavbls.pretty-ts-errors
yseop.vscode-yseopml
zignd.html-css-class-completion
)

for i in ${pkglist[@]}; do
  code --install-extension $i
done
