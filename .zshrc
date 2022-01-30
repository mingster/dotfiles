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
   export EDITOR='mvim'
fi

export PATH="/usr/local/sbin:$PATH"
#export JAVA_HOME=`/usr/libexec/java_home -v 1.8.0_131`
export JAVA_HOME=`/usr/libexec/java_home -v 11.0.12`
export PATH="/usr/local/opt/openjdk@11/bin:$PATH"
export CPPFLAGS="-I/usr/local/opt/openjdk@11/include"

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
