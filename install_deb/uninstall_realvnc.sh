sudo apt remove realvnc_vnc-server

echo '--remove configurations--'
sudo rm -rf /etc/vnc/
sudo rm -rf /root/.vnc/
rm -rf ~/.vnc/
sudo rm -rf /etc/pam.d/vncserver*
sudo rm -rf /etc/init.d/vncserver*
sudo rm -rf /etc/rc*.d/vncserver*
sudo rm -rf /usr/lib/systemd/system/vncserver*
sudo rm -rf /tmp/.vnc

echo 'done.'
