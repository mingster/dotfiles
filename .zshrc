#export CPPFLAGS="-I/usr/local/opt/openjdk@11/include"
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

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

  autoload -Uz compinit
  compinit
fi

ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
  export LDFLAGS="-L/opt/homebrew/opt/postgresql@18/lib"
  export CPPFLAGS="-I/opt/homebrew/opt/postgresql@18/include"
elif [[ "$ARCH" == "x86_64" ]]; then
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

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$ZSH/custom"
#ZSH_THEME="$ZSH_CUSTOM/themes/powerlevel9k/powerlevel9k"
ZSH_THEME="powerlevel10k/powerlevel10k"
POWERLEVEL10K_LEFT_PROMPT_ELEMENTS=(context dir dir_writable vcs)
POWERLEVEL10K_RIGHT_PROMPT_ELEMENTS=(status ram)

#POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(context dir dir_writable vcs vi_mode)
#POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status background_jobs history ram load time)

# 若當前登入的帳號為你的帳號 xxx，就不用特別顯示出來
#DEFAULT_USER="mtsai"
#POWERLEVEL9K_MODE='nerdfont-complete'

plugins=(
  git
  macos
  rake
  iterm2
  zsh-autosuggestions
)

source $ZSH/oh-my-zsh.sh

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# bun completions
[ -s "/Users/mtsai/.bun/_bun" ] && source "/Users/mtsai/.bun/_bun"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

[ -f "$HOME/dotfiles/.env" ] && source "$HOME/dotfiles/.env"

export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"
