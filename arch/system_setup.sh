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

    # Check sudo availability once. Over SSH without a TTY, sudo requires a password
    # interactively and will time out. _sudo() skips gracefully so re-runs don't abort.
    _SUDO_OK=false
    if sudo -n true 2>/dev/null; then
        _SUDO_OK=true
    else
        echo "system_setup: sudo requires an interactive password — package installs will be skipped."
        echo "  Run directly on the machine (not over SSH) to install/update packages."
    fi

    _sudo() {
        if [ "$_SUDO_OK" = "true" ]; then
            sudo "$@"
        else
            echo "system_setup: [no sudo] skipping: sudo $*" >&2
        fi
    }

    # ----------------------------------------------------------------------------------------------
    # Applications
    # ----------------------------------------------------------------------------------------------
    echo ""
    echo -e "\033[1;35mKeyboard delay...\033[0m"
    echo ""
    #gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 25
    #gsettings set org.gnome.desktop.peripherals.keyboard delay 300

    # https://wiki.archlinux.org/title/Display_Power_Management_Signaling
    # xset needs a running X server and DISPLAY (skip SSH, headless, Wayland-only).
    if [ -n "${DISPLAY:-}" ] && command -v xset >/dev/null 2>&1; then
        xset s 180 180 2>/dev/null || true
    else
        echo "Skipping xset (no DISPLAY or not under X11)."
    fi

    echo ""
    echo -e "\033[1;35mInstalling applications...\033[0m"
    echo ""

    echo ""
    echo -e "\033[1;35myay\033[0m"
    echo ""
    if ! command -v yay >/dev/null 2>&1; then
        _sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si
        yay -Y --gendb
        if [ -d ./yay ]; then
            rm -rf yay
        fi
    else
        echo "yay already installed, skipping."
    fi

    echo ""
    echo -e "\033[1;35mEssentials\033[0m"
    echo ""
    _sudo pacman -S --noconfirm --needed openssh rsync wget curl unzip ufw cron
    _sudo pacman -S --noconfirm --needed github-cli kdiff3 fish tmux neovim lf kitty fastfetch fzf net-tools
    _sudo pacman -S --noconfirm --needed chromium firefox

    echo ""
    echo -e "\033[1;35m fish shell \033[0m"
    echo ""
    if ! grep -qF "$(which fish)" /etc/shells; then
        which fish | _sudo tee -a /etc/shells
    fi

    echo ""
    echo -e "\033[1;35m alacritty \033[0m"
    echo ""
    _sudo pacman -S --noconfirm --needed alacritty

    if [ ! -d "${HOME}/.config/alacritty" ]; then
        mkdir -p "${HOME}/.config/alacritty"
        cp "$HOME/dotfiles/.config/alacritty/"* "$HOME/.config/alacritty/"
        git clone https://github.com/catppuccin/alacritty.git "$HOME/dotfiles/.config/alacritty/catppuccin"
    fi

    echo ""
    echo -e "\033[1;35m nano editor \033[0m"
    echo ""
    _sudo pacman -S --noconfirm --needed nano-syntax-highlighting
    if [ ! -d ${HOME}/GitHub ]; then
        mkdir -p ${HOME}/GitHub
    fi

    [ -d "$HOME/GitHub/nanorc" ] || git clone https://github.com/scopatz/nanorc.git "$HOME/GitHub/nanorc"
    #echo "include ~/GitHub/nanorc/*.nanorc" >> ~/.nanorc
    #cp ~/GitHub/nanorc/*.nanorc /usr/share/nano/

    echo ""
    echo -e "\033[1;35m micro editor \033[0m"
    echo ""
    _sudo pacman -S --noconfirm --needed micro
    micro -plugin install editorconfig
    micro -plugin install fish
    micro -plugin install fzf

    if [ ! -d ${HOME}/.config/micro ]; then
        mkdir -p ${HOME}/.config/micro
    fi
    #rm -f $HOME/dotfiles/.config/micro/bindings.json
    #ln -s $HOME/dotfiles/.config/micro/bindings.json $HOME/.config/micro/

    # lazygit
    if ! command -v lazygit >/dev/null 2>&1; then
        LG_VERSION=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
        cd /tmp &&
            wget "https://github.com/jesseduffield/lazygit/releases/download/v${LG_VERSION}/lazygit_${LG_VERSION}_Linux_x86_64.tar.gz" &&
            tar xfv "lazygit_${LG_VERSION}_Linux_x86_64.tar.gz" &&
            _sudo cp lazygit /usr/bin/ &&
            rm -f "lazygit_${LG_VERSION}_Linux_x86_64.tar.gz"
    else
        echo "lazygit already installed, skipping."
    fi

    # ----------------------------------------------------------------------------------------------
    # Appearance
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mInstalling theme, icons, fonts...\033[0m"
    echo ""

    # fonts

    #sudo pacman -S --needed unzip fonts-recommended fonts-ubuntu fonts-font-awesome fonts-terminus
    mkdir -p $HOME/.local/share/fonts

    if [ ! -d "$HOME/.local/share/fonts/Hack" ]; then
        cd /tmp
        wget "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/Hack.zip"
        unzip "Hack.zip" -d "$HOME/.local/share/fonts/Hack/"
        rm "Hack.zip"
        fc-cache -f -v
    else
        echo "Hack Nerd Font already installed, skipping."
    fi

    # theme - https://store.kde.org/p/1294174/


    # ----------------------------------------------------------------------------------------------
    # Permissions
    # ----------------------------------------------------------------------------------------------

    echo ""
    echo -e "\033[1;35mMaking sure configs and scripts are executable...\033[0m"
    echo ""

    chmod +x $HOME/dotfiles/arch/*.sh
    chmod +x $HOME/dotfiles/script/*.sh

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
    ln -sfn "$HOME/dotfiles/.config/.inputrc" "$HOME/.inputrc"

    ln -sfn "$HOME/dotfiles/.config/kitty" "$HOME/.config/kitty"

    bash "$HOME/dotfiles/script/install_asdf.sh"
    sh "$HOME/dotfiles/script/install_node.sh"
    sh "$HOME/dotfiles/script/install_java_dev.sh"

    mkdir -p "${HOME}/.config/fish"
    ln -sfn "$HOME/dotfiles/.config/fish/config.fish" "$HOME/.config/fish/config.fish"

    if [ "$SHELL" != "$(which fish)" ]; then
        echo 'change default shell to fish'
        chsh -s "$(which fish)"
    fi

    if command -v fish >/dev/null 2>&1; then
        fish "$HOME/dotfiles/script/setup_fishshell.fish"
    else
        echo "system_setup: fish not found; skipping setup_fishshell.fish" >&2
    fi

    ln -sfn "$HOME/dotfiles/.config/tmux" "$HOME/.config/tmux"
    ln -sfn "$HOME/dotfiles/.config/nvim" "$HOME/.config/nvim"
    ln -sfn "$HOME/dotfiles/.config/lf" "$HOME/.config/lf"
    ln -sfn "$HOME/dotfiles/.config/lazygit" "$HOME/.config/lazygit"

    mkdir -p "$HOME/.local/share/nvim"
    mkdir -p "$HOME/.local/state/nvim"
    mkdir -p "$HOME/.cache/nvim"

    mkdir -p $HOME/dotfiles/.agents
    ln -sfn $HOME/dotfiles/.agents $HOME/.agents

    bash "$HOME/dotfiles/script/install_claude.sh"

    bash "$HOME/dotfiles/script/install_zed.sh"

    bash "$HOME/dotfiles/script/setup-claude-code.sh"
    # Claude Desktop on Linux uses ~/.config/Claude/ (if installed via AppImage/Flatpak).
    # The mac-specific setup script handles macOS ~/Library path; on Arch we just ensure
    # ~/.agents and ~/.claude are wired (already done above via setup-claude-code.sh).

    bash "$HOME/dotfiles/script/setup-cursor.sh"

    sh $HOME/dotfiles/script/link-cursor-user.sh

    #
    echo 'bluetooth'
    # https://www.jeremymorgan.com/tutorials/linux/how-to-bluetooth-arch-linux/
    #
    _sudo pacman -S --noconfirm --needed bluez bluez-utils blueman

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
        _sudo ufw default deny incoming
        _sudo ufw default allow outgoing
        _sudo ufw enable
        _sudo ufw allow 22/tcp
        _sudo ufw allow 80
        _sudo ufw allow 443
        _sudo ufw allow 1935
        _sudo ufw allow 5900

        #sudo ufw allow syncthing
    fi

    _sudo systemctl start sshd
    _sudo systemctl enable sshd


    ## POST INSTALL

    # ********** how to import shotcuts.kksrc programatically ??? ********

    # as root, create crontab: ping 8.8.8.8 || systemctl restart NetworkManager

    ## edit /etc/ssh/sshd_config
    #replace
    # Subsystem sftp /usr/lib/openssh/sftp-server
    #by
    # Subsystem sftp internal-sftp

    gh auth status >/dev/null 2>&1 || gh auth login

    ## ssh-copyid

    ## noip
    # https://www.noip.com/support/knowledgebase/install-linux-3-x-dynamic-update-client-duc
    ##cd /tmp && git clone https://aur.archlinux.org/noip.git && cd noip && makepkg -Acs && sudo pacmau -U noip-3.1.0-1-x86_64.pkg.tar.zst

    #yay -S noip

    # vscode
    yay -S --noconfirm --needed code
    bash "$HOME/dotfiles/script/setup-vscode.sh"

    ## update the system
    _sudo pacman -S --noconfirm --needed ca-certificates
    _sudo pacman -Syu

    # cursor
    yay -S --noconfirm --needed cursor-bin

    bash "$HOME/dotfiles/script/install_aws_cli.sh"
    bash "$HOME/dotfiles/script/install_gcloud.sh"

    if [ -f "$HOME/dotfiles/arch/install_misc_software.sh" ]; then
        bash "$HOME/dotfiles/arch/install_misc_software.sh"
    fi

}

simple

echo ""
echo -e "\033[1;32mEverything is set up, time to reboot!\033[0m"
echo ""
