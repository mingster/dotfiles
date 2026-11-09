#!/bin/bash

orca_before=$(pacman -Q stably-orca-bin 2>/dev/null)

# yay runs pacman -Syu first, then upgrades AUR packages (stably-orca-bin among them).
# Pass --noconfirm to run it unattended.
yay -Syu "$@"

# An upgraded Orca keeps running the old version until it restarts. Restart it when
# this run changed its version, detached because quitting Orca ends a shell running
# inside it.
orca_exe=/opt/stably-orca/orca-ide
if [ "$(pacman -Q stably-orca-bin 2>/dev/null)" != "$orca_before" ] && pgrep -f "^$orca_exe( |$)" >/dev/null; then
  echo "Restarting Orca to load $(pacman -Q stably-orca-bin)"
  setsid -f bash -c "pkill -f '^$orca_exe( |\$)'
    n=0; while pgrep -f '^$orca_exe( |\$)' >/dev/null && [ \$n -lt 30 ]; do sleep 1; n=\$((n + 1)); done
    exec stably-orca" >/dev/null 2>&1
fi
