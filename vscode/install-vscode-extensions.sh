#!/bin/bash

# execute command
# -------------------
# curl -s https://raw.githubusercontent.com/mingster/dotfiles/master/vscode/install-vscode-extensions.sh | /bin/bash

# Visual Studio Code :: Package list
# get this list by: code --list-extensions
pkglist=(
    alicebeckett.brightscriptcomment
    anteprimorac.html-end-tag-labels
    anthropic.claude-code
    benjaminbenais.copilot-theme
    biomejs.biome
    bradlc.vscode-tailwindcss
    cesium.gltf-vscode
    christian-kohler.npm-intellisense
    christian-kohler.path-intellisense
    ckolkman.vscode-postgres
    codezombiech.gitignore
    davidanson.vscode-markdownlint
    dbaeumer.vscode-eslint
    donjayamanne.githistory
    dotjoshjohnson.xml
    editorconfig.editorconfig
    esbenp.prettier-vscode
    exodiusstudios.comment-anchors
    formulahendry.auto-close-tag
    formulahendry.auto-rename-tag
    foxundermoon.shell-format
    github.codespaces
    github.copilot-chat
    github.github-vscode-theme
    github.remotehub
    heybourn.headwind
    jasonnutter.search-node-modules
    josee9988.minifyall
    maptz.regionfolder
    mathiasfrohlich.kotlin
    mikestead.dotenv
    mjmcaulay.roku-deploy-vscode
    mrmlnc.vscode-scss
    ms-vscode.remote-repositories
    pkief.material-icon-theme
    pkief.material-product-icons
    planbcoding.vscode-react-refactor
    prisma.prisma
    redhat.java
    redhat.vscode-xml
    richie5um2.vscode-sort-json
    rokucommunity.brightscript
    s-nlf-fh.glassit
    sburg.vscode-javascript-booster
    shd101wyy.markdown-preview-enhanced
    sibiraj-s.vscode-scss-formatter
    tomoki1207.pdf
    unifiedjs.vscode-mdx
    usernamehw.errorlens
    vscjava.vscode-gradle
    vscjava.vscode-java-debug
    vscjava.vscode-java-dependency
    vscjava.vscode-java-pack
    vscjava.vscode-java-test
    vscjava.vscode-maven
    vsls-contrib.gistfs
    yoavbls.pretty-ts-errors
    yseop.vscode-yseopml
    yzane.markdown-pdf
    zignd.html-css-class-completion
)

for i in ${pkglist[@]}; do
  code --install-extension $i
done
