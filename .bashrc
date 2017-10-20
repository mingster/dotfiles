[ -n "$PS1" ]
#[ -n "$PS1" ] && source ~/.bash_profile;


export HOMEBREW_CASK_OPTS="--caskroom=/usr/local/Caskroom"

# Short of learning how to actually configure OSX, here's a hacky way to use
# GNU manpages for programs that are GNU ones, and fallback to OSX manpages otherwise
alias man='_() { echo $1; man -M $(brew --prefix)/opt/coreutils/libexec/gnuman $1 1>/dev/null 2>&1;  if [ "$?" -eq 0 ]; then man -M $(brew --prefix)/opt/coreutils/libexec/gnuman $1; else man $1; fi }; _'

export HOMEBREW_PREFIX=/usr/local
export MANPATH=$MANPATH:$HOMEBREW_PREFIX/opt/coreutils/libexec/gnuman

#Node.js
export NVM_DIR="$HOME/.nvm"

# fix grep error
unset GREP_OPTIONS
alias grep="/usr/bin/grep $GREP_OPTIONS"

# Add `~/bin` to the `$PATH`
export PATH="$HOME/bin:$PATH";

# Ensure user-installed binaries take precedence, mainly gnu
export PATH=/usr/local/bin:/usr/local/sbin:$PATH
export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"

# GO path
export PATH=$PATH:/usr/local/opt/go/libexec/bin


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



# Make vim the default editor
export EDITOR="vim";
# Set Default Editor (change 'Nano' to the editor of your choice)
# ------------------------------------------------------------
#export EDITOR=/usr/bin/vim

# Enable persistent REPL history for `node`.
NODE_REPL_HISTORY_FILE=~/.node_history;
# Allow 32³ entries; the default is 1000.
NODE_REPL_HISTORY_SIZE='32768';

# Larger bash history (allow 32³ entries; default is 500)
export HISTSIZE=32768;
export HISTFILESIZE=$HISTSIZE;
export HISTCONTROL=ignoredups;
# Make some commands not show up in history
export HISTIGNORE="ls:cd:cd -:pwd:exit:date:* --help";

# Prefer US English and use UTF-8
export LANG="en_US.UTF-8";
export LC_ALL="en_US.UTF-8";

# Highlight section titles in manual pages
export LESS_TERMCAP_md="${yellow}";

# Don’t clear the screen after quitting a manual page
export MANPAGER="less -X";

# Always enable colored `grep` output
#export GREP_OPTIONS="--color=auto";

# Link Homebrew casks in `/Applications` rather than `~/Applications`
#export HOMEBREW_CASK_OPTS="--appdir=/Applications";

if [ -d ~/.local/bin ]; then
  export PATH=~/.local/bin:$PATH
fi

#Jenv
#export PATH="$HOME/.jenv/bin:$PATH"
#eval "$(jenv init -)"

# Init jenv
#http://davidcai.github.io/blog/posts/install-multiple-jdk-on-mac/
if which jenv > /dev/null; then eval "$(jenv init -)"; fi
