[ -n "$PS1" ]
#[ -n "$PS1" ] && source ~/.bash_profile;


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
