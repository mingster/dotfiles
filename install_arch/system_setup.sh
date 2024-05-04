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

    # ----------------------------------------------------------------------------------------------
    # Applications
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mInstalling applications...\033[0m"
    echo ""

    sudo pacman -S --needed xorg sddm
    sudo pacman -S --needed plasma kde-applications
    sudo pacman -S --needed rsync wget curl unzip micro firefox
    #build-essential ufw rsync unzip curl wget wput network-manager xinput feh arandr zathura scrot syncthing htop alsa-utils pulseaudio libavcodec-extra qpdfview inkscape exfat-fuse libreoffice udiskie mpv lightdm xsecurelock psmisc brightnessctl
    sudo pacman -S --needed zram-tools kdiff3 fish tmux neovim lf kitty neofetch fzf neofetch github-cli
    sudo pacman -S --needed --noconfirm base-devel

    # add fish to system shell
    #echo $(which fish) | sudo tee -a /etc/shells

    # ----------------------------------------------------------------------------------------------
    # Appearance
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mInstalling theme, icons, fonts...\033[0m"
    echo ""

    # Hack Nerd font

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
    gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 25
    gsettings set org.gnome.desktop.peripherals.keyboard delay 300

    echo ""
    echo -e "\033[1;35mSetting up directories and symlinks...\033[0m"
    echo ""

    # create missing directories and files

    # symlinks
    ln -s -f ~/dotfiles/.config/.inputrc ~/.inputrc
    ln -s -f ~/dotfiles/.config/kitty ~/.config/kitty

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
}

simple

#sudo apt-get update && sudo apt-get upgrade && sudo apt-get full-upgrade

echo ""
echo -e "\033[1;32mEverything is set up, time to reboot!\033[0m"
echo ""
