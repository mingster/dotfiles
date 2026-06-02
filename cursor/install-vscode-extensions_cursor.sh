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
    dotjoshjohnson.xml
    editorconfig.editorconfig
    esbenp.prettier-vscode
    exodiusstudios.comment-anchors
    foxundermoon.shell-format
    github.github-vscode-theme
    josee9988.minifyall
    mikestead.dotenv
    pkief.material-icon-theme
    pkief.material-product-icons
    prisma.prisma
    richie5um2.vscode-sort-json
    s-nlf-fh.glassit
    tomoki1207.pdf
    unifiedjs.vscode-mdx
    redhat.vscode-xml

#dbaeumer.vscode-eslint
#ohziinteractivestudio.ohzi-vscode-glb-viewer

#ms-mssql.data-workspace-vscode
#ms-mssql.mssql
#ms-mssql.sql-bindings-vscode
#ms-mssql.sql-database-projects-vscode

#ms-dotnettools.vscode-dotnet-runtime
#anysphere.csharp
#rokucommunity.brightscript

#redhat.java
#mathiasfrohlich.kotlin
#vscjava.vscode-gradle
#vscjava.vscode-java-debug
#vscjava.vscode-java-dependency
#vscjava.vscode-java-pack
#vscjava.vscode-java-test
#vscjava.vscode-maven

)

for i in ${pkglist[@]}; do
  cursor --install-extension $i
done
