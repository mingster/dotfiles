#!/bin/bash

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
