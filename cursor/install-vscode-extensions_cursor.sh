#!/bin/bash

# execute command
# -------------------
# curl -s https://raw.githubusercontent.com/mingster/dotfiles/master/vscode/install-vscode-extensions.sh | /bin/bash

# cursor :: Package list
# get this list by: cursor --list-extensions
pkglist=(
3xpo.regionfolding
biomejs.biome
bradlc.vscode-tailwindcss
davidanson.vscode-markdownlint
dbaeumer.vscode-eslint
dotjoshjohnson.xml
exodiusstudios.comment-anchors
foxundermoon.shell-format
github.github-vscode-theme
josee9988.minifyall
maptz.regionfolder
mathiasfrohlich.kotlin
mikestead.dotenv
ms-mssql.data-workspace-vscode
ms-mssql.mssql
ms-mssql.sql-bindings-vscode
ms-mssql.sql-database-projects-vscode
pkief.material-icon-theme
pkief.material-product-icons
prisma.prisma
redhat.java
richie5um2.vscode-sort-json
s-nlf-fh.glassit
vscjava.vscode-gradle
vscjava.vscode-java-debug
vscjava.vscode-java-dependency
vscjava.vscode-java-pack
vscjava.vscode-java-test
vscjava.vscode-maven

# roku dev
mjmcaulay.roku-deploy-vscode
RokuCommunity.brightscript
AliceBeckett.brightscriptcomment
redhat.vscode-xml
)

for i in ${pkglist[@]}; do
  cursor --install-extension $i
done
