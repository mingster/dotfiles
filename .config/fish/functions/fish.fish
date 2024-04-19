# Back in the day, with zsh I was used to restart the shell by running zsh.
# To do the same with fish, create a new funcion ~/.config/fish/functions/fish.fish:

# A way to reload the shell à la "zsh"
function fish
  source ~/.config/fish/config.fish
end
