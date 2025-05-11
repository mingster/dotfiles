#!/bin/bash

# execute command
# -------------------
# curl -s https://raw.githubusercontent.com/mingster/dotfiles/master/vscode/install-vscode-extensions.sh | /bin/bash

# cursor :: Package list
# get this list by: cursor --list-extensions
pkglist=(
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
mikestead.dotenv
ms-mssql.data-workspace-vscode
ms-mssql.mssql
ms-mssql.sql-bindings-vscode
ms-mssql.sql-database-projects-vscode
pkief.material-icon-theme
pkief.material-product-icons
prisma.prisma
richie5um2.vscode-sort-json
s-nlf-fh.glassit
)

for i in ${pkglist[@]}; do
  cursor --install-extension $i
done
