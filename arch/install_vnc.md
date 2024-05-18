
# install RealVNC from its deb package

https://www.baeldung.com/linux/arch-install-deb-package
https://linuxgenie.net/download-install-realvnc-arch-linux/

```
git clone https://aur.archlinux.org/realvnc-vnc-server-6.git

cd realvnc-vnc-server-6
makepkg -si
```

# install tigervnc

https://wiki.archlinux.org/title/TigerVNC

```
sudo pacman -S tigervnc
```

```
vncpasswd

chmod 0600 ~/.vnc/passwd

```



as root:

```
echo ":1=$USER"  >> /etc/tigervnc/vncserver.users
```

or append your username to the file.


```
sudo systemctl enable --now vncserver@:1.service
```


```
sudo cat <<EOF > ~/.vnc/config
session=$XDG_SESSION_DESKTOP
geometry=1920x1080
localhost
alwaysshared
EOF
```

for display :1

```
sudo systemctl enable --now vncserver@:1.service
```

```
sudo micro /etc/systemd/system/x0vncserver.service


[Unit]
Description=Remote desktop service (VNC) for :0 display
Requires=display-manager.service
After=network-online.target
After=display-manager.service

[Service]
Type=simple
Environment=HOME=/root
Environment=XAUTHORITY=/var/run/lightdm/root/:0
ExecStart=x0vncserver -display :0 -rfbauth ~/.vnc/passwd
Restart=on-failure
RestartSec=500ms

[Install]
WantedBy=multi-user.target

```
