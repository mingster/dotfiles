set fish_greeting ""
neofetch


switch (uname)
    case Linux

    case Darwin
      # homebrew
      eval "$(/usr/local/bin/brew shellenv)"

      set -x HOMEBREW_NO_ANALYTICS 1
      set -x HOMEBREW_NO_ENV_HINTS 1

      set -gx JAVA_HOME /Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
      set -gx PATH $PATH $HOME/Library/Android/sdk/platform-tools
      set -gx PATH $PATH $JAVA_HOME/bin

      # node v20.x
      set -gx PATH $PATH /usr/local/opt/node@20/bin

      # mysql-client
      set -gx PATH $PATH /usr/local/opt/mysql-client/bin

      # activate asdf
      #source /usr/local/opt/asdf/libexec/asdf.sh

    case FreeBSD NetBSD DragonFly

    case '*'

end





if status --is-interactive
end


#
# universal
#
set -gx PATH $PATH /usr/local/bin
set -gx PATH $PATH /usr/local/sbin
set -gx PATH $PATH ~/bin
set -gx PATH $PATH ~/bin2
set -x PATH $HOME/.local/bin $PATH

#set -x EDITOR vim
#set -x VISUAL $EDITOR

# set -gx PATH $PATH /usr/bin
# set -gx PATH $PATH /bin
# set -gx PATH $PATH /usr/sbin
# set -gx PATH $PATH /sbin

# nvm
set -gx NVM_DIR $HOME/.nvm

if status is-interactive
    # Commands to run in interactive sessions can go here
end

# tmux

# Print a new line after any command
source ~/.config/fish/functions/postexec_newline.fish


# Clear line on CTRL + C
# Sometimes it still doesn't work well enough on node.js scripts :(
bind --preset \cC 'cancel-commandline'

# Auto-switch nvm version on cd
# Requires a ~/.node-version file with a valid node version
# https://github.com/jorgebucaran/nvm.fish/pull/186
if type -q nvm
  function __nvm_auto --on-variable PWD
  nvm use --silent 2>/dev/null # Comment out the silent flag for debugging
  end
  __nvm_auto
end

# Pyenv setup
# Requires `brew install pyenv`
if type -q pyenv
  status --is-interactive; and source (pyenv init -|psub)
end

# `ls` → `ls -laG` abbreviation
abbr -a -g ls ls -laG

# `ls` → `exa` abbreviation
# Requires `brew install exa`
if type -q exa
  abbr --add -g ls 'exa --long --classify --all --header --git --no-user --tree --level 1'
end

# `cat` → `bat` abbreviation
# Requires `brew install bat`
if type -q bat
  abbr --add -g cat 'bat'
end

# `rm` → `trash` abbreviation (moves files to the trash instead of deleting them)
# Requires `brew install trash`
if type -q trash
  abbr --add -g rm 'trash'
end


if status --is-login

end

function on_exit --on-event fish_exit
    echo fish is now exiting
end
