#export CPPFLAGS="-I/usr/local/opt/openjdk@11/include"
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export CLICOLOR=1

if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
fi

if [ -f ~/.functions ]; then
    source ~/.functions
fi

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
   export EDITOR='vim'
else
   export EDITOR='nano'
fi

if type brew &>/dev/null; then
  FPATH=$(brew --prefix)/share/zsh-completions:$FPATH
fi

autoload -Uz compinit
compinit

ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" && -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  # PostgreSQL client tools (psql, createdb) come from the keg-only libpq on every host.
  # postgresql@18 stays after it for a host that still has that formula installed.
  export PATH="/opt/homebrew/opt/libpq/bin:/opt/homebrew/opt/postgresql@18/bin:$PATH"
  export LDFLAGS="-L/opt/homebrew/opt/libpq/lib"
  export CPPFLAGS="-I/opt/homebrew/opt/libpq/include"
elif [[ "$ARCH" == "x86_64" && -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
  export PATH="/usr/local/share/google-cloud-sdk/bin:$PATH"
  export PATH="/usr/local/opt/libpq/bin:/usr/local/opt/postgresql@18/bin:$PATH"
  export PATH="/usr/local/opt/llvm/bin:$PATH"
fi

export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/bin2:$PATH"
export PATH="$HOME/bin:$PATH"
export PATH="$HOME/dotfiles/bin:$PATH"
export PATH="/Applications/_dev/Visual Studio Code.app/Contents/Resources/app/bin:$PATH"
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
export PATH="$HOME/.antigravity/antigravity/bin:$PATH"

if [[ "$OSTYPE" == darwin* ]]; then
  alias ls='ls -lagG'
else
  alias ls='ls -lag --color=auto'
fi


# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# API keys and tokens are never exported from startup files. A tool that needs one reads it from the
# macOS keychain for that one command only: see bin/with-keychain and docs/agents/keys-in-keychain.md.
# Only on macOS: other hosts have no keychain helper, so gemini runs as installed there.
[[ "$(uname -s)" == Darwin ]] && gemini() { with-keychain GEMINI_API_KEY -- gemini "$@"; }

export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"

if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi


# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

export PATH="$HOME/.stripe/bin:$PATH"
