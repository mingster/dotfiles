#!/bin/bash

sudo journalctl --flush --rotate --vacuum-time=1s
sudo journalctl --user --flush --rotate --vacuum-time=1s
sudo journalctl --vacuum-size=500M
sudo pacman -Scc
