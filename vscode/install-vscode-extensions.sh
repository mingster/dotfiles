#!/bin/bash

# execute command
# -------------------
# curl -s https://raw.githubusercontent.com/mingster/dotfiles/master/install/vscode/install-vscode-extensions.sh | /bin/bash

# Visual Studio Code :: Package list
pkglist=(
ms-vscode.vscode-typescript-next
dbaeumer.vscode-eslint
GitHub.copilot
github.vscode-pull-request-github
github.github-vscode-theme
pkief.material-icon-theme
pkief.material-product-icons
github.codespaces
github.remotehub
github.copilot-chat
github.vscode-github-actions
vsls-contrib.gistfs
planbcoding.vscode-react-refactor
eamodio.gitlens
donjayamanne.githistory
alefragnani.project-manager
codezombiech.gitignore
EditorConfig.EditorConfig

# makedown
davidanson.vscode-markdownlint
shd101wyy.markdown-preview-enhanced


dsznajder.es7-react-js-snippets
mgmcdermott.vscode-language-babel
BenjaminBenais.copilot-theme
jasonnutter.search-node-modules
christian-kohler.npm-intellisense
christian-kohler.path-intellisense
exodiusstudios.comment-anchors
mikestead.dotenv
usernamehw.errorlens
anteprimorac.html-end-tag-labels
#visualstudioexptteam.vscodeintellicode
#wmaurer.vscode-jumpy
#mrmlnc.vscode-scss
rangav.vscode-thunder-client
sburg.vscode-javascript-booster
esbenp.prettier-vscode
rvest.vs-code-prettier-eslint
bradlc.vscode-tailwindcss
Zignd.html-css-class-completion
formulahendry.auto-rename-tag
formulahendry.auto-close-tag
prisma.prisma
visualstudioexptteam.intellicode-api-usage-examples
maptz.regionfolder

# sql
mtxr.sqltools
mtxr.sqltools-driver-mysql
ms-mssql.mssql

# scss
mrmlnc.vscode-scss
sibiraj-s.vscode-scss-formatter

# xml
redhat.vscode-xml

# yml
yseop.vscode-yseopml

#py
ms-python.python
cesium.gltf-vscode

foxundermoon.shell-format #shellscript

s-nlf-fh.glassit #GlassIt-VSC transparent theme (only work on linux)
)

for i in ${pkglist[@]}; do
  code --install-extension $i
done
