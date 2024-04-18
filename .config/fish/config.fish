if status is-interactive
    # Commands to run in interactive sessions can go here
    neofetch
    tmux
end

if status --is-login
  # set -gx PATH $PATH /usr/bin
  # set -gx PATH $PATH /bin
  # set -gx PATH $PATH /usr/sbin
  # set -gx PATH $PATH /sbin

    set -gx PATH $PATH /usr/local/bin
    set -gx PATH $PATH /usr/local/sbin
    set -gx PATH $PATH ~/bin
    set -gx PATH $PATH ~/bin2

    set -gx JAVA_HOME /Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
    set -gx PATH $PATH $HOME/Library/Android/sdk/platform-tools
    set -gx PATH $PATH $JAVA_HOME/bin

    # node v20.x
    set -gx PATH $PATH /usr/local/opt/node@20/bin

    # mysql-client
    set -gx PATH $PATH /usr/local/opt/mysql-client/bin

    # activate asdf
    #source /usr/local/opt/asdf/libexec/asdf.sh

    # nvm
    set -gx NVM_DIR $HOME/.nvm
end

function on_exit --on-event fish_exit
    echo fish is now exiting
end
