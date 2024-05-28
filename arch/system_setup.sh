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
    gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 25
    gsettings set org.gnome.desktop.peripherals.keyboard delay 300

    # https://wiki.archlinux.org/title/Display_Power_Management_Signaling
    xset s 180 180	#Change blank time to 3 min

    echo ""
    echo -e "\033[1;35mInstalling applications...\033[0m"
    echo ""

    echo ""
    echo -e "\033[1;35myay\033[0m"
    echo ""
    sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si
    yay -Y --gendb

    echo ""
    echo -e "\033[1;35mEssentials\033[0m"
    echo ""
    sudo pacman -S -y --needed openssh rsync wget curl unzip ufw cron
    sudo pacman -S --needed github-cli kdiff3 fish tmux neovim lf kitty neofetch fzf neofetch
    sudo pacman -S -y --needed chromium firefox

    echo ""
    echo -e "\033[1;35m add fish to system shell \033[0m"
    echo ""
    echo $(which fish) | sudo tee -a /etc/shells

    echo ""
    echo -e "\033[1;35m alacritty \033[0m"
    echo ""
    sudo pacman -S --needed alacritty

    if [ ! -d ${HOME}/.config/alacritty ];
    then
        mkdir -p ${HOME}/.config/alacritty
    fi
    ln -s ~/dotfiles/.config/alacritty $HOME/.config/

    git clone https://github.com/catppuccin/alacritty.git ~/dotfiles/.config/alacritty/catppuccin

    echo ""
    echo -e "\033[1;35m micro editor \033[0m"
    echo ""
    sudo pacman -S --needed micro
    micro -plugin install editorconfig
    micro -plugin install fish
    micro -plugin install fzf

    if [ ! -d ${HOME}/.config/micro ];
    then
        mkdir -p ${HOME}/.config/micro
    fi
    ln -s ~/dotfiles/.config/micro/bindings.json $HOME/.config/micro/

    # lazygit
    cd /tmp && \
    wget https://github.com/jesseduffield/lazygit/releases/download/v0.41.0/lazygit_0.41.0_Linux_x86_64.tar.gz && \
    tar xfv lazygit_0.41.0_Linux_x86_64.tar.gz && \
    sudo cp lazygit /usr/bin/

    # ----------------------------------------------------------------------------------------------
    # Appearance
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mInstalling theme, icons, fonts...\033[0m"
    echo ""

    # fonts

    #sudo pacman -S --needed unzip fonts-recommended fonts-ubuntu fonts-font-awesome fonts-terminus
    mkdir -p ~/.local/share/fonts

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

    for font in ${fonts[@]}
    do
        wget https://github.com/ryanoasis/nerd-fonts/releases/download/v3.1.1/$font.zip
    	unzip $font.zip -d $HOME/.local/share/fonts/$font/
        rm $font.zip
    done

    fc-cache -f -v

    # ----------------------------------------------------------------------------------------------
    # Permissions
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mMaking sure configs and scripts are executable...\033[0m"
    echo ""

    sudo chmod +x ~/dotfiles/install_arch/*.sh
    sudo chmod +x ~/dotfiles/script/*.sh

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

    # create missing directories and files
    if [ ! -d ${HOME}/.local/bin ];
    then
        mkdir -p ${HOME}/.local/bin
        cp ./bin/ ${HOME}/.local/bin/
        chmod +x ${HOME}/.local/bin/*
    fi

    # symlinks
    ln -s -f ~/dotfiles/.config/.inputrc ~/.inputrc
    ln -s -f ~/dotfiles/.config/kitty ~/.config/

    if [ ! -d ${HOME}/.config/fish ];
    then
        mkdir -p ${HOME}/.config/fish
    fi
    cp -rf -v ~/dotfiles/.config/fish ${HOME}/.config/

    #
    echo 'change default shell to fish'
    #
    chsh -s $(which fish)

    ln -s -f ~/dotfiles/.config/tmux $HOME/.config/tmux
    ln -s -f ~/dotfiles/.config/nvim $HOME/.config/nvim
    ln -s -f ~/dotfiles/.config/lf $HOME/.config/lf
    ln -s -f ~/dotfiles/.config/lazygit $HOME/.config/lazygit

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
        sudo ufw allow 22
        sudo ufw allow 80
        sudo ufw allow 443
        sudo ufw allow 1935
        sudo ufw allow 5900

        sudo ufw allow syncthing
    fi

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
    //https://www.noip.com/support/knowledgebase/install-linux-3-x-dynamic-update-client-duc
    ##cd /tmp && git clone https://aur.archlinux.org/noip.git && cd noip && makepkg -Acs && sudo pacmau -U noip-3.1.0-1-x86_64.pkg.tar.zst

    yay -S noip

    # vscode
    yay -S code

    ## update the system
    sudo pacman -Syu
}

simple

echo ""
echo -e "\033[1;32mEverything is set up, time to reboot!\033[0m"
echo ""
