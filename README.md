# Ming's dotfiles

this dotfiles allows you quickly set up environment on a newly installed macos.

Check [this](http://dotfiles.github.io) out if you need more info.

This dotfiles is based on the [Mathias’s legendary](https://github.com/mathiasbynens/dotfiles) dotfiles. A couple
changes are added to my favorites.

## Overview

- change macos' perferences (osx.sh)
- [Homebrew](https://brew.sh)
- [Fish shell](https://fishshell.com/)
- [Fisher](https://github.com/jorgebucaran/fisher) - Plugin manager
- [Tide](https://github.com/IlanCosman/tide) - Shell theme. Use version 6: `fisher install ilancosman/tide@v6`
- [Nerd fonts](https://github.com/ryanoasis/nerd-fonts) - Powerline-patched fonts. I use Hack.
- [tmux]() - window manager
- [lf File Manager](https://www.joshmedeski.com/posts/manage-files-with-lf/)
- [lazygit]()



<!--
- [z for fish](https://github.com/jethrokuan/z) - Directory jumping
- [Eza](https://github.com/eza-community/eza) - `ls` replacement
- [ghq](https://github.com/x-motemen/ghq) - Local Git repository organizer
- [fzf](https://github.com/PatrickF1/fzf.fish) - Interactive filtering
-->

## Installation

### 1. Grab this repository:

```
mkdir ~/GitHub
cd ~/GitHub
git clone https://github.com/mingster/dotfiles.git && cd dotfiles
```

### 2. Software Update and "Command Line Tools"

Update macos and install command line tools:

```
sh ~/GitHub/dotfiles/install/osxprep.sh
```

### 3. Sensible OS X defaults

When setting up a new Mac, you may want to set some sensible OS X defaults. Review it carefully to best suit your own preferences. To execute:

```bash
sh ~/GitHub/dotfiles/install/osx.sh
```

### 4. Shell set up

cli and iterm2 are your best friends everyday:

```
./install/bootstrap.sh
```

iterm2 preferences are in the init folder.

### 5. Install essential apps

Review and modify before you run. This will install a lot of cli programs and applications such as Chrome browser etc.

```
./install/brew.sh
```

## 6. (Optional) Software / Dev environment

- [vscode related](https://github.com/mingster/dotfiles/tree/master/install/vscode)
- android.sh: for Java / Android development
- aws.sh: amazon development environment
- datastores.sh: database apps
- pydata.sh: Python development environment
- web.sh: node.js based apps

## Feedback

Suggestions/improvements
[welcome](https://github.com/mingster/dotfiles/issues)!

## Thanks to…

- [josean-dev / dev-environment-files](https://github.com/josean-dev/dev-environment-files)
- [How To Make An Amazing Custom Menu Bar For Your Mac With Sketchybar](https://www.josean.com/posts/sketchybar-setup)
- @ptb and [his _OS X Lion Setup_ repository](https://github.com/ptb/Mac-OS-X-Lion-Setup)
- [Ben Alman](http://benalman.com/) and his [dotfiles repository](https://github.com/cowboy/dotfiles)
- [Chris Gerke](http://www.randomsquared.com/) and his [tutorial on creating an OS X SOE master image](http://chris-gerke.blogspot.com/2012/04/mac-osx-soe-master-image-day-7.html) + [_Insta_ repository](https://github.com/cgerke/Insta)
- [Cãtãlin Mariş](https://github.com/alrra) and his [dotfiles repository](https://github.com/alrra/dotfiles)
- [Gianni Chiappetta](http://gf3.ca/) for sharing his [amazing collection of dotfiles](https://github.com/gf3/dotfiles)
- [Jan Moesen](http://jan.moesen.nu/) and his [ancient `.bash_profile`](https://gist.github.com/1156154) + [shiny _tilde_ repository](https://github.com/janmoesen/tilde)
- [Lauri ‘Lri’ Ranta](http://lri.me/) for sharing [loads of hidden preferences](http://osxnotes.net/defaults.html)
- [Matijs Brinkhuis](http://hotfusion.nl/) and his [dotfiles repository](https://github.com/matijs/dotfiles)
- [Nicolas Gallagher](http://nicolasgallagher.com/) and his [dotfiles repository](https://github.com/necolas/dotfiles)
- [Sindre Sorhus](http://sindresorhus.com/)
- [Tom Ryder](http://blog.sanctum.geek.nz/) and his [dotfiles repository](https://github.com/tejr/dotfiles)
- [Kevin Suttle](http://kevinsuttle.com/) and his [dotfiles repository](https://github.com/kevinSuttle/dotfiles) and [OSXDefaults project](https://github.com/kevinSuttle/OSXDefaults), which aims to provide better documentation for [`~/.osx`](http://mths.be/osx)
- [Haralan Dobrev](http://hkdobrev.com/)

- anyone who [contributed a patch](https://github.com/mingster/dotfiles/contributors) or [made a helpful suggestion](https://github.com/mingster/dotfiles/issues)
