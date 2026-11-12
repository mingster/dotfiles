# Login shells read this after ~/.zprofile, where installers put their own bin directories first.
# Keep the dotfiles wrappers in front, as .zshrc does for interactive shells, so `zsh -l -c agy` runs bin/agy.
export PATH="$HOME/dotfiles/bin:$PATH"
