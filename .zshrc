export ZSH="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$ZSH/custom"
#ZSH_THEME="$ZSH_CUSTOM/themes/powerlevel9k/powerlevel9k"
ZSH_THEME="powerlevel9k/powerlevel9k"
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(context dir dir_writable vcs)
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status ram)

#POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(context dir dir_writable vcs vi_mode)
#POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status background_jobs history ram load time)

# 若當前登入的帳號為你的帳號 xxx，就不用特別顯示出來
#DEFAULT_USER="mtsai"
POWERLEVEL9K_MODE='nerdfont-complete'

plugins=(
  git
  macos
  rake
  iterm2
  zsh-autosuggestions
)

source $ZSH/oh-my-zsh.sh
source ~/.aliases

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

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
#export PATH="/usr/local/sbin:/usr/bin:$PATH"
export JAVA_HOME=`/usr/libexec/java_home -v 1.8.0_321`
#export JAVA_HOME=`/usr/libexec/java_home -v 11.0.12`
#export PATH="/usr/local/opt/openjdk@11/bin:$PATH"
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"

export PATH="$JAVA_HOME/bin:$PATH"
#export PATH="/opt/gradle/gradle-7.4.2/bin:$PATH"
#export DROID_SDK=`/Users/$USER/Library/Android/sdk`
#export PATH="$DROID_SDK/platform-tools:$PATH"

#export CPPFLAGS="-I/usr/local/opt/openjdk@11/include"
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
source /usr/local/opt/chruby/share/chruby/chruby.sh
source /usr/local/opt/chruby/share/chruby/auto.sh
chruby ruby-3.1.2
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
fi
export PATH="/usr/local/sbin:$PATH"
