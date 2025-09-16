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

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:~/bin:$PATH"
#export PATH="/usr/local/sbin:/usr/bin:$PATH"
#export JAVA_HOME=`/usr/libexec/java_home -v 1.8.0_321`
#export JAVA_HOME=`/usr/libexec/java_home -v 11.0.12`
#export JAVA_HOME=/Library/Java/JavaVirtualMachines/openjdk-21.0.1.jdk
#export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
#export PATH="/usr/local/opt/openjdk@11/bin:$PATH"
#export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
#export PATH="$JAVA_HOME/bin:$PATH"
#export PATH="/opt/gradle/gradle-7.4.2/bin:$PATH"
#export DROID_SDK=`/Users/$USER/Library/Android/sdk`
#export PATH="$DROID_SDK/platform-tools:$PATH"

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

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# node v20.x
#export PATH="/usr/local/opt/node@20/bin:$PATH"

# mysql-client
#export PATH="/usr/local/opt/mysql-client/bin:$PATH"

# activate asdf
. $(brew --prefix asdf)/libexec/asdf.sh
# https://mac.install.guide/ruby/12.html
# source /usr/local/opt/chruby/share/chruby/chruby.sh
# source /usr/local/opt/chruby/share/chruby/auto.sh
# chruby ruby-3.1.2

#export PYENV_ROOT="$HOME/.pyenv"
#export PATH="$PYENV_ROOT/bin:$PATH"
#if command -v pyenv 1>/dev/null 2>&1; then
#  eval "$(pyenv init --path)"
#  eval "$(pyenv init -)"
#fi

#export NVM_DIR="$HOME/.nvm"
#[ -s "/usr/local/opt/nvm/nvm.sh" ] && \. "/usr/local/opt/nvm/nvm.sh"  # This loads nvm
#[ -s "/usr/local/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/usr/local/opt/nvm/etc/bash_completion.d/nvm"  # This loads nvm bash_completion
