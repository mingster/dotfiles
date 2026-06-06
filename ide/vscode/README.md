# vscode-dotfiles

VS Code(Visual Studio Code) setting files

## Enviroment tested

- Mac OS X with brew
- Linux Ubuntu 16.04/18.04
- Windows 11

## Setup

### Mac
#### Install VS Code
Execute following command:

```sh
brew install --cask visual-studio-code
```

#### Install extensions
Execute following command:

```sh
curl -s https://raw.githubusercontent.com/mingster/dotfiles/master/vscode/install-vscode-extensions.sh | /bin/bash
```

#### Memo
json file path: `~/Library/Application\ Support/Code/User/settings.json`

### Linux
#### Install VS Code(deb package)
Execute following commands:

```sh
$ curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
$ sudo mv microsoft.gpg /etc/apt/trusted.gpg.d/microsoft.gpg
$ sudo sh -c 'echo "deb [arch=amd64] http://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list'
$ sudo apt update
$ sudo apt install code
```

#### Install VS Code(snap package)
Note: Not recommended. Japanese environment does not work.

Execute following command:

```sh
$ sudo snap install code --classic
```

Execute following command for uninstalling:

```sh
$ sudo snap remove code
```


### Raspberry Pi
#### Install VS Code
Execute following commands:

```sh
$ cd && wget -O insider.deb https://update.code.visualstudio.com/latest/linux-deb-armhf/insider
$ sudo apt install ./insider.deb
$ sudo mv /usr/bin/code-insiders /usr/bin/code
```

### Windows


#### Memo
json file place: `/mnt/c/Users/<user name>/AppData/Roaming/Code/User/settings.json`


## CREDIT

This code is modified from https://github.com/karaage0703/vscode-dotfiles/

## References
- https://github.com/karaage0703/vscode-dotfiles/
- https://qiita.com/karaage0703/items/fb50b6ac5c175b9b1045
- https://qiita.com/ayatokura/items/4301e0d1d8b339f722eb
- https://code.headmelted.com/
