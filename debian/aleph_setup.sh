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

    sudo apt install -y syncthing rsync curl mpv

    # mullvad
    if ! command -v mullvad &> /dev/null; then
        cd /tmp
        wget https://mullvad.net/download/app/deb/latest
        cp latest latest.deb
        sudo apt install -y ./latest.deb
        rm latest.deb latest
        cd
    else
        echo ""
        echo -e "\033[0;35mMullvad is already installed, skipping...\033[0m"
        echo ""
    fi
}

simple

echo ""
echo -e "\033[1;32mEverything is set up, time to reboot!\033[0m"
echo ""
