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

    sudo apt install -y
        xorg bspwm picom build-essential apt-transport-https software-properties-common \
        make cmake polybar suckless-tools rofi pass lua5.4 \
        network-manager xinput feh arandr zathura scrot \
        syncthing htop alsa-utils pulseaudio libavcodec-extra qpdfview inkscape \
        exfat-fuse libreoffice udiskie mpv lightdm xsecurelock psmisc brightnessctl \
        zram-tools

    sudo apt install -y git ufw rsync unzip curl wget wput
    sudo apt install -y kdiff3 fish tmux neovim lf kitty neofetch fzf
    sudo apt install -y chromium-browser

    # add fish to system shell
    echo $(which fish) | sudo tee -a /etc/shells

    # micro editor
    sudo apt install -y micro
    micro -plugin install editorconfig
    micro -plugin install fish
    micro -plugin install fzf

    if [ ! -d ${HOME}/.config/micro ];
    then
        mkdir -p ${HOME}/.config/micro
    fi
    ln -s ~/dotfiles/.config/micro/bindings.json $HOME/.config/micro/


    # lazygit
    cd /tmp
    wget https://github.com/jesseduffield/lazygit/releases/download/v0.46.0/lazygit_0.46.0_Linux_x86_64.tar.gz
    tar xfv lazygit_0.46.0_Linux_x86_64.tar.gz
    sudo cp lazygit /usr/bin/

    #remove games
    sudo apt purge iagno lightsoff four-in-a-row gnome-robots pegsolitaire gnome-2048 hitori gnome-klotski gnome-mines gnome-mahjongg gnome-sudoku quadrapassel swell-foop gnome-tetravex gnome-taquin aisleriot gnome-chess five-or-more gnome-nibbles tali ; sudo apt autoremove

    ## Github Desktop for Ubuntu
    ## Get the @shiftkey package feed
    wget -qO - https://apt.packages.shiftkey.dev/gpg.key | gpg --dearmor | sudo tee /usr/share/keyrings/shiftkey-packages.gpg > /dev/null
    sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/shiftkey-packages.gpg] https://apt.packages.shiftkey.dev/ubuntu/ any main" > /etc/apt/sources.list.d/shiftkey-packages.list'
    ## Install Github Desktop for Ubuntu
    sudo apt update && sudo apt install github-desktop


    # kvm/qemu
    if [[ $(systemd-detect-virt) = *kvm* ]]; then
        echo ""
        echo -e "\033[0;35mInside a virtual machine, skipping KVM/QEMU install...\033[0m"
        echo ""
    else
        echo ""
        echo -e "\033[1;35mInstalling KVM/QEMU...\033[0m"
        echo ""
        sudo apt install -y \
            qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils virtinst \
            libvirt-daemon virt-manager
        #sudo virsh net-start default
        #sudo virsh net-autostart default
        #sudo modprobe vhost_net
        #sudo usermod -a -G libvirt $(whoami)
    fi

    # passmenu
    if ! command -v passmenu &> /dev/null; then
        sudo cp /usr/share/doc/pass/examples/dmenu/passmenu /usr/bin/passmenu
        sudo chmod +x /usr/bin/passmenu
    else
        echo ""
        echo -e "\033[0;35mpassmenu is already installed, skipping...\033[0m"
        echo ""
    fi

    # rofi-pass
    if ! command -v rofi-pass &> /dev/null; then
        cd /tmp
        wget https://github.com/carnager/rofi-pass/archive/master.zip
        unzip master.zip
        rm master.zip
        cd rofi-pass-master
        sudo make
        mkdir -p ~/.config/rofi-pass
        mv config.example ~/.config/rofi-pass/config
        cd ..
        sudo rm -rf rofi-pass-master
        cd
    else
        echo ""
        echo -e "\033[0;35mrofi-pass is already installed, skipping...\033[0m"
        echo ""
    fi

    # rofi-power-menu
    if ! command -v rofi-power-menu &> /dev/null; then
        cd /tmp
        wget https://raw.githubusercontent.com/jluttine/rofi-power-menu/master/rofi-power-menu
        sudo mv rofi-power-menu /usr/local/bin
        sudo chmod +x /usr/local/bin/rofi-power-menu
        cd
    else
        echo ""
        echo -e "\033[0;35mrofi-power-menu is already installed, skipping...\033[0m"
        echo ""
    fi

    # wezterm
    if ! command -v c &> /dev/null; then
        curl -LO https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/wezterm-20240203-110809-5046fc22.Ubuntu22.04.deb
        sudo apt install -y ./wezterm-20240203-110809-5046fc22.Ubuntu22.04.deb

        # Wez's Terminal Emulator
        #curl -fsSL https://apt.fury.io/wez/gpg.key | sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
        #echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' | sudo tee /etc/apt/sources.list.d/wezterm.list

        #curl -LO https://github.com/wez/wezterm/releases/download/20230408-112425-69ae8472/WezTerm-20230408-112425-69ae8472-Ubuntu20.04.AppImage
        #chmod +x WezTerm-20230408-112425-69ae8472-Ubuntu20.04.AppImage
        #mkdir -p $HOME/.local/bin
        #mv ./WezTerm-20230408-112425-69ae8472-Ubuntu20.04.AppImage $HOME/.local/bin/wezterm
    else
        echo ""
        echo -e "\033[0;35mWezTerm is already installed, skipping...\033[0m"
        echo ""
    fi


    # ----------------------------------------------------------------------------------------------
    # Appearance
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mInstalling theme, icons, fonts...\033[0m"
    echo ""

    # arc gtk
    sudo apt install -y gtk2-engines-murrine arc-theme

    # papirus icons
    sudo sh -c "echo 'deb http://ppa.launchpad.net/papirus/papirus/ubuntu focal main' > /etc/apt/sources.list.d/papirus-ppa.list"
    sudo apt-key adv --recv-keys --keyserver keyserver.ubuntu.com E58A9D36647CAE7F
    sudo apt update
    sudo apt install papirus-icon-theme libreoffice-style-papirus

    # Hack Nerd font

    sudo apt install -y unzip fonts-recommended fonts-ubuntu fonts-font-awesome fonts-terminus
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

    # phinger cursors
    if [ ! -d "/usr/share/icons/phinger-cursors" ]; then
        wget -cO- https://github.com/phisch/phinger-cursors/releases/latest/download/phinger-cursors-variants.tar.bz2 | sudo tar xfj - -C /usr/share/icons
    else
        echo ""
        echo -e "\033[0;35phinger-cursors is already installed, skipping...\033[0m"
        echo ""
    fi

    # ----------------------------------------------------------------------------------------------
    # Permissions
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mMaking sure configs and scripts are executable...\033[0m"
    echo ""

    sudo chmod +x ~/dotfiles/.config/bspwm/bspwmrc
    sudo chmod +x ~/dotfiles/install_deb/*.sh
    sudo chmod +x ~/dotfiles/script/*.sh

    # ----------------------------------------------------------------------------------------------
    # Directories, symlinks, and configs
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mKeyboard delay...\033[0m"
    echo ""
    gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 25
    gsettings set org.gnome.desktop.peripherals.keyboard delay 200

    echo ""
    echo -e "\033[1;35mSetting up directories and symlinks...\033[0m"
    echo ""

    # create missing directories and files
    mkdir -p ~/.config/{bspwm,sxhkd,rofi,rofi-pass,gtkrc-2.0,gtk-3.0,zathura,lightdm}

    ## index.theme
    mkdir -p ~/.icons/default
    rm -rf ~/.icons/default/index.theme && cp ~/dotfiles/install_deb/index.theme ~/.icons/default/

    # symlinks
    ln -s -f ~/dotfiles/.config/.inputrc ~/.inputrc
    ln -s -f ~/dotfiles/.config/gtk/.gtkrc-2.0 ~/.config/.gtkrc-2.0
    cp ~/dotfiles/.config/gtk/settings.ini.sample ~/.config/gtk-3.0/settings.ini
    ln -s -f ~/dotfiles/.config/mimeapps.list ~/.config/mimeapps.list
    ln -s -f ~/dotfiles/.config/bspwm/bspwmrc ~/.config/bspwm/bspwmrc
    ln -s -f ~/dotfiles/.config/sxhkd/sxhkdrc ~/.config/sxhkd/sxhkdrc
    ln -s -f ~/dotfiles/.config/wezterm ~/.config/wezterm
    ln -s -f ~/dotfiles/.config/kitty ~/.config/kitty

    ln -s -f ~/dotfiles/config/rofi/oner.rasi ~/.config/rofi/oner.rasi
    ln -s -f ~/dotfiles/config/rofi-pass/config ~/.config/rofi-pass/config
    ln -s -f ~/dotfiles/config/zathura/zathurarc ~/.config/zathura/zathurarc
    ln -s -f ~/dotfiles/config/index.theme ~/.icons/default/index.theme
    sudo ln -s -f ~/dotfiles/config/index.theme /usr/share/icons/default/index.theme
    sudo ln -s -f ~/dotfiles/config/lightdm/lightdm-gtk-greeter.conf /etc/lightdm/lightdm-gtk-greeter.conf

    #ln -s -f ~/dotfiles/.config/fish $HOME/.config/fish
    #ln -s ~/dotfiles/.config/fish $HOME/.config/fish
    if [ ! -d ${HOME}/.config/fish ];
    then
        mkdir -p ${HOME}/.config/fish
    fi
    cp -rf -v ~/dotfiles/.config/fish/ ${HOME}/.config/

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

    # ----------------------------------------------------------------------------------------------
    # Change GRUB background
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mChanging GRUB background...\033[0m"
    echo ""

    sudo cp ~/dotfiles/install_deb/wallpaper/wallpaper.png /boot/grub
    sudo update-grub

    # ----------------------------------------------------------------------------------------------
    # more fish shell setup
    # ----------------------------------------------------------------------------------------------
    ../script/setup_fishshell.sh
}

simple
sudo apt-get update && sudo apt-get upgrade && sudo apt-get full-upgrade


echo ""
echo -e "\033[1;32mEverything is set up, time to reboot!\033[0m"
echo ""
