#export CPPFLAGS="-I/usr/local/opt/openjdk@11/include"
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export CLICOLOR=1

if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
fi

if [[ "$OSTYPE" == darwin* ]]; then
  alias ls='ls -lagG'
else
  alias ls='ls -lag --color=auto'
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

  autoload -Uz compinit
  compinit
fi

ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" && -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
  export LDFLAGS="-L/opt/homebrew/opt/postgresql@18/lib"
  export CPPFLAGS="-I/opt/homebrew/opt/postgresql@18/include"
elif [[ "$ARCH" == "x86_64" && -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
  export PATH="/usr/local/share/google-cloud-sdk/bin:$PATH"
  export PATH="/usr/local/opt/postgresql@18/bin:$PATH"
fi

export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/bin2:$PATH"
export PATH="$HOME/bin:$PATH"
export PATH="$HOME/dotfiles/bin:$PATH"
export PATH="/Applications/_dev/Visual Studio Code.app/Contents/Resources/app/bin:$PATH"
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
export PATH="$HOME/.antigravity/antigravity/bin:$PATH"

export ZSH="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$ZSH/custom"
ZSH_THEME=""

plugins=(
  git
  macos
  rake
  iterm2
  zsh-autosuggestions
)

[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"


# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

[ -f "$HOME/dotfiles/.env" ] && source "$HOME/dotfiles/.env"

export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"

if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

