[ -n "$PS1" ]
#[ -n "$PS1" ] && source ~/.bash_profile;

# Ensure user-installed binaries take precedence
export PATH=/usr/local/bin:/usr/local/sbin:$PATH

# Add `~/bin` to the `$PATH`
export PATH="$HOME/bin:$PATH";

# GO path
export PATH=$PATH:/usr/local/opt/go/libexec/bin

export HOMEBREW_CASK_OPTS="--caskroom=/usr/local/Caskroom"

export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"

# Short of learning how to actually configure OSX, here's a hacky way to use
# GNU manpages for programs that are GNU ones, and fallback to OSX manpages otherwise
alias man='_() { echo $1; man -M $(brew --prefix)/opt/coreutils/libexec/gnuman $1 1>/dev/null 2>&1;  if [ "$?" -eq 0 ]; then man -M $(brew --prefix)/opt/coreutils/libexec/gnuman $1; else man $1; fi }; _'

export HOMEBREW_PREFIX=/usr/local
export MANPATH=$MANPATH:$HOMEBREW_PREFIX/opt/coreutils/libexec/gnuman

export NVM_DIR="$HOME/.nvm"

#temporarily turn off virtualenv if needed
#syspip(){
#   PIP_REQUIRE_VIRTUALENV="" pip "$@"
#}

# Locate virtualenvwrapper binary
if [ -f ~/.local/bin/virtualenvwrapper.sh ]; then
    export VENVWRAP=~/.local/bin/virtualenvwrapper.sh
fi

if [ ! -z $VENVWRAP ]; then
    # virtualenvwrapper -------------------------------------------
    # make sure env directory exists; else create it
    [ -d $HOME/projects/env ] || mkdir -p $HOME/projects/env
    export WORKON_HOME=$HOME/projects/env
    source $VENVWRAP

    # virtualenv --------------------------------------------------
    export VIRTUALENV_USE_DISTRIBUTE=true

    # pip ---------------------------------------------------------
    export PIP_REQUIRE_VIRTUALENV=true
    export PIP_VIRTUALENV_BASE=$WORKON_HOME
    export PIP_REQUIRE_VIRTUALENV=true
    export PIP_RESPECT_VIRTUALENV=true

    # cache pip-installed packages to avoid re-downloading
    export PIP_DOWNLOAD_CACHE=$HOME/.pip/cache
fi
