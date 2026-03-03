# install vnc on Wayland

如果您在 Mac 上習慣使用 VNC Viewer（例如 RealVNC Viewer），在 KDE Plasma Wayland 環境下，最穩定且原生的解決方案是 Krfb。
Krfb 是 KDE 官方開發的桌面共享伺服器，它能解決您之前遇到的協定相容性問題。

1. 安裝 Krfb
在 Arch Linux 上安裝：

```bash
sudo pacman -S krfb
```

2. 設定 Krfb

從應用程式選單啟動 「桌面分享 (Krfb)」。

點擊右下角的 「配置 (Configure)」。

在 「網路 (Network)」 選項中：
勾選 「啟用桌面共享」。
勾選 「允許未邀約的連線」（這樣您才能隨時連線）。

在 「安全 (Security)」 選項中：

設定一個 「無人看守密碼」 (Unattended Password)。這是您從 Mac 連線時要輸入的密碼。
建議取消勾選「每次連線都要確認」，否則你必須在 Arch 電腦前點擊允許。

3. 在 Mac 端連線

打開您的 VNC Viewer。
輸入您的 Arch Linux IP 位址（預設埠為 5900）。
輸入您在 Krfb 設定的 無人看守密碼。

4. 設定開機自動啟動
KDE 預設不會在登入後自動執行 Krfb，您可以手動加入：
開啟 「系統設定」 (System Settings) > 「啟動與關閉」 (Startup and Shutdown)。
點擊 「自動啟動」 (Autostart) > 「新增」 (Add Application)。
搜尋並選擇 Krfb。

5. 疑難排解 (如果連不上)
防火牆：若有啟用 ufw，請執行 sudo ufw allow 5900/tcp。
Wayland 權限：在連線時，KDE 可能會跳出一個視窗問你「是否允許分享螢幕」，請選擇「始終允許」或對應的螢幕名稱。

為什麼不推薦剛才的 KRDP？
因為 KRDP 使用的是 RDP 協定，VNC Viewer 無法連線 RDP 伺服器。如果您堅持使用 VNC 軟體，Krfb 是唯一針對 Plasma 深度整合的選擇。
