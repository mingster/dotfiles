#!/bin/bash

# execute command
# -------------------
# curl -s https://raw.githubusercontent.com/mingster/dotfiles/master/install/vscode/install-vscode-extensions.sh | /bin/bash

# Visual Studio Code :: Package list
# get this list by: code --list-extensions
pkglist=(
alefragnani.project-manager
anteprimorac.html-end-tag-labels
austenc.tailwind-docs
benjaminbenais.copilot-theme
bradlc.vscode-tailwindcss
cesium.gltf-vscode
christian-kohler.npm-intellisense
christian-kohler.path-intellisense
codeium.codeium
codezombiech.gitignore
continue.continue
cweijan.dbclient-jdbc
cweijan.vscode-mysql-client2
davidanson.vscode-markdownlint
dbaeumer.vscode-eslint
donjayamanne.githistory
dotjoshjohnson.xml
dsznajder.es7-react-js-snippets
eamodio.gitlens
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
github.vscode-github-actions
github.vscode-pull-request-github
heybourn.headwind
jasonnutter.search-node-modules
josee9988.minifyall
maptz.regionfolder
mgmcdermott.vscode-language-babel
mikestead.dotenv
mrmlnc.vscode-scss
ms-mssql.data-workspace-vscode
ms-mssql.mssql
ms-mssql.sql-bindings-vscode
ms-mssql.sql-database-projects-vscode
ms-vscode-remote.remote-containers
ms-vscode.azure-repos
ms-vscode.remote-repositories
ms-vscode.vscode-typescript-next
ms-vsliveshare.vsliveshare
mtxr.sqltools
mtxr.sqltools-driver-mysql
pkief.material-icon-theme
pkief.material-product-icons
planbcoding.vscode-react-refactor
prisma.prisma
rangav.vscode-thunder-client
redhat.vscode-xml
rvest.vs-code-prettier-eslint
s-nlf-fh.glassit
sburg.vscode-javascript-booster
shd101wyy.markdown-preview-enhanced
sibiraj-s.vscode-scss-formatter
usernamehw.errorlens
visualstudioexptteam.intellicode-api-usage-examples
vsls-contrib.gistfs
yseop.vscode-yseopml
zignd.html-css-class-completion
)

for i in ${pkglist[@]}; do
  code --install-extension $i
done
