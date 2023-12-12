#!/bin/bash

# execute command
# -------------------
# curl -s https://raw.githubusercontent.com/karaage0703/vscode-dotfiles/master/install-vscode-extensions.sh | /bin/bash

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
#sibiraj-s.vscode-scss-formatter
#mrmlnc.vscode-scss
rangav.vscode-thunder-client
sburg.vscode-javascript-booster
esbenp.prettier-vscode
rvest.vs-code-prettier-eslint
bradlc.vscode-tailwindcss
Zignd.html-css-class-completion
formulahendry.auto-rename-tag
formulahendry.auto-close-tag
shd101wyy.markdown-preview-enhanced
prisma.prisma
visualstudioexptteam.intellicode-api-usage-examples
maptz.regionfolder
mtxr.sqltools
ms-mssql.mssql

#py
ms-python.python
)

for i in ${pkglist[@]}; do
  code --install-extension $i
done
