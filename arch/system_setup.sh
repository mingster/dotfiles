#!/bin/bash

set -e
trap 'catch $? $LINENO' EXIT

catch() {
    if [ "$1" != "0" ]; then
        echo ""
        echo -e "\033[1;31mInstallation failed!\033[0m"
        echo -e "\033[1;31mError $1 occurred on $2\033[0m"
        echo ""
    fi
}

simple() {

    echo ""
    echo -e "\033[1;35mSystem Setup for arch\033[0m"
    echo ""

    # ----------------------------------------------------------------------------------------------
    # Applications
    # ----------------------------------------------------------------------------------------------
    echo ""
    echo -e "\033[1;35mKeyboard delay...\033[0m"
    echo ""
    #gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 25
    #gsettings set org.gnome.desktop.peripherals.keyboard delay 300

    # https://wiki.archlinux.org/title/Display_Power_Management_Signaling
    xset s 180 180 #Change blank time to 3 min

    echo ""
    echo -e "\033[1;35mInstalling applications...\033[0m"
    echo ""

    echo ""
    echo -e "\033[1;35myay\033[0m"
    echo ""
    sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si
    yay -Y --gendb

    # remove work dir when done
    if [ -d ./yay ]; then
        rm -rf yay
    fi

    echo ""
    echo -e "\033[1;35mEssentials\033[0m"
    echo ""
    sudo pacman -S --noconfirm --needed openssh rsync wget curl unzip ufw cron
    sudo pacman -S --noconfirm --needed github-cli kdiff3 fish tmux neovim lf kitty neofetch fzf neofetch net-tools
    sudo pacman -S --noconfirm --needed chromium firefox

    echo ""
    echo -e "\033[1;35m add fish to system shell \033[0m"
    echo ""
    echo $(which fish) | sudo tee -a /etc/shells

    echo ""
    echo -e "\033[1;35m alacritty \033[0m"
    echo ""
    sudo pacman -S --noconfirm --needed alacritty

    if [ -d ${HOME}/.config/alacritty ]; then
        mkdir -p ${HOME}/.config/alacritty
        cp $HOME/dotfiles/.config/alacritty/* $HOME/.config/alacritty/
        git clone https://github.com/catppuccin/alacritty.git $HOME/dotfiles/.config/alacritty/catppuccin
    fi

    echo ""
    echo -e "\033[1;35m nano editor \033[0m"
    echo ""
    pacman -S --noconfirm --needed nano-syntax-highlighting
    if [ ! -d ${HOME}/GitHub ]; then
        mkdir -p ${HOME}/GitHub
    fi

    git clone https://github.com/scopatz/nanorc.git ~/GitHub/nanorc
    #echo "include ~/GitHub/nanorc/*.nanorc" >> ~/.nanorc
    #cp ~/GitHub/nanorc/*.nanorc /usr/share/nano/

    echo ""
    echo -e "\033[1;35m micro editor \033[0m"
    echo ""
    sudo pacman -S --noconfirm --needed micro
    micro -plugin install editorconfig
    micro -plugin install fish
    micro -plugin install fzf

    if [ ! -d ${HOME}/.config/micro ]; then
        mkdir -p ${HOME}/.config/micro
    fi
    #rm -f $HOME/dotfiles/.config/micro/bindings.json
    #ln -s $HOME/dotfiles/.config/micro/bindings.json $HOME/.config/micro/

    # lazygit
    cd /tmp &&
        wget https://github.com/jesseduffield/lazygit/releases/download/v0.46.0/lazygit_0.46.0_Linux_x86_64.tar.gz &&
        tar xfv lazygit_0.46.0_Linux_x86_64.tar.gz &&
        sudo cp lazygit /usr/bin/

    # ----------------------------------------------------------------------------------------------
    # Appearance
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mInstalling theme, icons, fonts...\033[0m"
    echo ""

    # fonts

    #sudo pacman -S --needed unzip fonts-recommended fonts-ubuntu fonts-font-awesome fonts-terminus
    mkdir -p $HOME/.local/share/fonts

    cd /tmp
    fonts=(
        "CascadiaCode"
        "FiraCode"
        "Hack"
        "Inconsolata"
        "JetBrainsMono"
        "Meslo"
        "Mononoki"
        "RobotoMono"
        "SourceCodePro"
        "UbuntuMono"
    )

    for font in ${fonts[@]}; do
        wget https://github.com/ryanoasis/nerd-fonts/releases/download/v3.1.1/$font.zip
        unzip $font.zip -d $HOME/.local/share/fonts/$font/
        rm $font.zip
    done

    fc-cache -f -v

    # theme - https://store.kde.org/p/1294174/


    # ----------------------------------------------------------------------------------------------
    # Permissions
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mMaking sure configs and scripts are executable...\033[0m"
    echo ""

    sudo chmod +x $HOME/dotfiles/arch/*.sh
    sudo chmod +x $HOME/dotfiles/script/*.sh

    # create missing directories and files
    if [ ! -d ${HOME}/.local/bin ]; then
        mkdir -p ${HOME}/.local/bin
        cp $HOME/dotfiles/arch/bin/* ${HOME}/.local/bin/
        chmod +x ${HOME}/.local/bin/*
    fi

    # ----------------------------------------------------------------------------------------------
    # Directories, symlinks, and configs
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mKeyboard delay...\033[0m"
    echo ""
    #gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 25
    #gsettings set org.gnome.desktop.peripherals.keyboard delay 300

    echo ""
    echo -e "\033[1;35mSetting up directories and symlinks...\033[0m"
    echo ""

    # symlinks
    ln -s -f $HOME/dotfiles/.config/.inputrc $HOME/.inputrc

    if [ -d ${HOME}/.config/kitty ]; then
        rm -rf ${HOME}/.config/kitty
    fi
    ln -s -f $HOME/dotfiles/.config/kitty $HOME/.config/

    if [ ! -d ${HOME}/.config/fish ]; then
        mkdir -p ${HOME}/.config/fish
    fi
    #rm -rf $HOME/.config/fish/config.fish
    ln -s $HOME/dotfiles/.config/fish/config.fish $HOME/.config/fish/
    cp -rf -v $HOME/dotfiles/.config/fish ${HOME}/.config/

    #
    echo 'change default shell to fish'
    #
    chsh -s $(which fish)

    ln -s -f $HOME/dotfiles/.config/tmux $HOME/.config/tmux
    ln -s -f $HOME/dotfiles/.config/nvim $HOME/.config/nvim
    ln -s -f $HOME/dotfiles/.config/lf $HOME/.config/lf
    ln -s -f $HOME/dotfiles/.config/lazygit $HOME/.config/lazygit

    #
    echo 'bluetooth'
    # https://www.jeremymorgan.com/tutorials/linux/how-to-bluetooth-arch-linux/
    #
    sudo pacman -S bluez
    sudo pacman -S bluez-utils
    sudo pacman -S blueman

    # ----------------------------------------------------------------------------------------------
    # Configure ufw
    # ----------------------------------------------------------------------------------------------

    # inside a VM?
    if [[ $(systemd-detect-virt) = *kvm* ]]; then
        echo ""
        echo -e "\033[0;35mInside a virtual machine, skipping UFW setup...\033[0m"
        echo ""
    else
        echo ""
        echo -e "\033[1;35mConfiguring UFW...\033[0m"
        echo ""
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        sudo ufw enable
        sudo ufw allow 22/tcp
        sudo ufw allow 80
        sudo ufw allow 443
        sudo ufw allow 1935
        sudo ufw allow 5900

        #sudo ufw allow syncthing
    fi

    ## openssh
    sudo pacman -S openssh
    sudo systemctl start sshd
    sudo systemctl enable sshd


    ## POST INSTALL

    # ********** how to import shotcuts.kksrc programatically ??? ********

    # as root, create crontab: ping 8.8.8.8 || systemctl restart NetworkManager

    ## edit /etc/ssh/sshd_config
    #replace
    # Subsystem sftp /usr/lib/openssh/sftp-server
    #by
    # Subsystem sftp internal-sftp

    gh auth login

    ## ssh-copyid

    ## noip
    # https://www.noip.com/support/knowledgebase/install-linux-3-x-dynamic-update-client-duc
    ##cd /tmp && git clone https://aur.archlinux.org/noip.git && cd noip && makepkg -Acs && sudo pacmau -U noip-3.1.0-1-x86_64.pkg.tar.zst

    #yay -S noip

    # vscode
    yay -S --noconfirm code

    # copy settings
    mkdir ${HOME}/.config/Code\ -\ OSS
    if [ -d ${HOME}/.config/Code\ -\ OSS ]; then
        cp $HOME/dotfiles/vscode/vscode-settings.json $HOME/.config/Code\ -\ OSS/User/settings.json
    fi

    ## update the system
    sudo pacman -S ca-certificates
    sudo pacman -Syu

    # cursor
    #sudo snap install cursor
    yay -S cursor-bin

}

simple

echo ""
echo -e "\033[1;32mEverything is set up, time to reboot!\033[0m"
echo ""
