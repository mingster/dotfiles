#!/bin/bash
cd /tmp/

wget https://mega.nz/linux/repo/xUbuntu_23.10/amd64/megasync-xUbuntu_23.10_amd64.deb

sudo dpkg -i megasync-xUbuntu_23.10_amd64.deb

rm -rf megasync-xUbuntu_23.10_amd64.deb
