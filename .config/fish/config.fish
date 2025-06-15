set fish_greeting ""

switch (uname)
    case Linux
        set -gx XDG_CONFIG_HOME $HOME/.config
        set -gx JAVA_HOME /usr/lib/jvm/default
        set -gx CPPFLAGS $CPPFLAGS "-I/usr/lib/jvm/default/include"

        # activate asdf
        # ASDF configuration code
        if test -z $ASDF_DATA_DIR
            set _asdf_shims "$HOME/.asdf/shims"
        else
            set _asdf_shims "$ASDF_DATA_DIR/shims"
        end

        asdf completion fish > ~/.config/fish/completions/asdf.fish

        # Do not use fish_add_path (added in Fish 3.2) because it
        # potentially changes the order of items in PATH
        if not contains $_asdf_shims $PATH
            set -gx --prepend PATH $_asdf_shims
        end
        set --erase _asdf_shims

        set --export BUN_INSTALL "$HOME/.bun"
        set --export PATH $BUN_INSTALL/bin $PATH

        # gradle
        #set -gx GRADLE_HOME /usr/bin/gradle
        set -gx GRADLE_USER_HOME $HOME/.gradle
        #fish_add_path $GRADLE_HOME/bin

        # android
        fish_add_path $HOME/Android/Sdk/platform-tools

    case Darwin
        set architecture (uname -m)

        set -x HOMEBREW_NO_ANALYTICS 1
        set -x HOMEBREW_NO_ENV_HINTS 1

        # homebrew
        if test "$architecture" = "arm64"
            #echo "This Mac is using Apple Silicon."
            eval "$(/opt/homebrew/bin/brew shellenv)"

            fish_add_path /opt/homebrew/bin

            # postgresql
            fish_add_path /opt/homebrew/opt/postgresql@17/bin

        else if test "$architecture" = "x86_64"
            #echo "This Mac is using Intel."
            eval "$(/usr/local/bin/brew shellenv)"

            fish_add_path /usr/local/bin

            # postgresql
            fish_add_path /usr/local/opt/postgresql@17/bin

        else
            echo "Unknown architecture: $architecture"
        end

        # ASDF configuration code
        if test -z $ASDF_DATA_DIR
            set _asdf_shims "$HOME/.asdf/shims"
        else
            set _asdf_shims "$ASDF_DATA_DIR/shims"
        end

        # Do not use fish_add_path (added in Fish 3.2) because it
        # potentially changes the order of items in PATH
        if not contains $_asdf_shims $PATH
            set -gx --prepend PATH $_asdf_shims
        end
        set --erase _asdf_shims

        set -gx XDG_CONFIG_HOME $HOME/.config
        fish_add_path /Applications/_dev/Visual\ Studio\ Code.app/Contents/Resources/app/bin/

        # bun
        set --export BUN_INSTALL "$HOME/.bun"
        set --export PATH $BUN_INSTALL/bin $PATH

        #neofetch

        #If you need to have openjdk first in your PATH, run:
        #fish_add_path /usr/local/opt/openjdk/bin

        #For compilers to find openjdk@11 you may need to set:
        #set -gx CPPFLAGS $CPPFLAGS "-I/usr/local/opt/openjdk/include"

        #set -gx JAVA_HOME /usr/local/opt/openjdk/
        #set -gx JAVA_HOME /Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home

        # gradle
        #set -gx GRADLE_HOME /usr/local/opt/gradle
        #set -gx GRADLE_USER_HOME $HOME/.gradle
        #fish_add_path $GRADLE_HOME/bin

        # android
        #fish_add_path $HOME/Library/Android/sdk/platform-tools
        #fish_add_path $JAVA_HOME/bin

        # node v20.x
        #fish_add_path /usr/local/opt/node@20/bin
        #set -gx LDFLAGS $LDFLAGS "-L/usr/local/opt/node@20/lib"
        #set -gx CPPFLAGS $CPPFLAGS "-I/usr/local/opt/node@20/include"

        # mysql-client
        # fish_add_path /usr/local/opt/mysql-client/bin


    case FreeBSD NetBSD DragonFly

    case '*'
end





if status --is-interactive
end


#
# universal
#
fish_add_path $HOME/bin
fish_add_path $HOME/bin2
fish_add_path $HOME/.local/bin

#echo $fish_user_paths | tr " " "\n" | nl

# fzf integration
fzf --fish | source

#set -x EDITOR vim
#set -x VISUAL $EDITOR
alias vi='vim -u ~/.vimrc'
abbr -a vi "vim -u ~/.vimrc"

# fish_add_path /usr/bin
# fish_add_path /bin
# fish_add_path /usr/sbin
# fish_add_path /sbin

# nvm
#set -gx NVM_DIR $HOME/.nvm

if status is-interactive
    # Commands to run in interactive sessions can go here
end

# tmux

# Print a new line after any command
source $HOME/.config/fish/functions/postexec_newline.fish


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
