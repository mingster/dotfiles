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
github.codespaces
github.remotehub
github.copilot-chat
github.vscode-github-actions
planbcoding.vscode-react-refactor
eamodio.gitlens
donjayamanne.githistory
alefragnani.project-manager
codezombiech.gitignore
EditorConfig.EditorConfig
rodrigovallades.es7-react-js-snippets
mgmcdermott.vscode-language-babel
BenjaminBenais.copilot-theme
jasonnutter.search-node-modules
christian-kohler.npm-intellisense
christian-kohler.path-intellisense
esbenp.prettier-vscode
rvest.vs-code-prettier-eslint
bradlc.vscode-tailwindcss
Zignd.html-css-class-completion
formulahendry.auto-rename-tag
christian-kohler.path-intellisense
shd101wyy.markdown-preview-enhanced
)

for i in ${pkglist[@]}; do
  code --install-extension $i
done
