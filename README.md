# Ming's dotfiles
DotFiles allows you quickly set up enviornment on a newly installed OSX. Check <a href="http://dotfiles.github.io">this
</a> out if you're not familar with it.

My dotfiles is based on the <a href="https://github.com/mathiasbynens/dotfiles">Mathias’s legendary dotfiles</a>, a couple
changes are added to my favourites:

1. .osx script: updates to my accustomed looks/feel & settings.
2. add python development setup

## Pre-Installation
1. <a href="http://iterm2.com">iTerm2</a>
2. <a href="http://brew.sh">Brew</a>
```bash
ruby -e "$(curl -fsSL https://raw.github.com/Homebrew/homebrew/go/install)"
```
3. install git first
```bash
brew install git
```

## DotFiles Installation

### Using Git and the bootstrap script

You can clone the repository wherever you want. (I like to keep it in `~/projects/dotfiles`, with `~/dotfiles` as a symlink.) The bootstrapper script will pull in the latest version and copy the files to your home folder.

```bash
git clone https://github.com/mathiasbynens/dotfiles.git && cd dotfiles && source bootstrap.sh
```

To execute, `cd` into your local `dotfiles` repository and then:

```bash
source bootstrap.sh
```

To update later on, just run that command again.


### Sensible OS X defaults

When setting up a new Mac, you may want to set some sensible OS X defaults.  Review it carefully to best suit your own
preferences.  To execute, do this:

```bash
./.osx
```

### Install Homebrew formulae

When setting up a new Mac, you may want to install some common [Homebrew](http://brew.sh/) formulae (after installing Homebrew, of course):

```bash
brew bundle ~/Brewfile
```

### Install native apps with `brew cask`

<a href="https://github.com/caskroom/homebrew-cask">Cask</a> install GUI Mac applications such as Google Chrome and Adium using HomeBrew.

Review the <code>~/Caskfile</code> for the installation list.  To execute, run this:

```bash
brew bundle ~/Caskfile
```

## Feedback

Suggestions/improvements
[welcome](https://github.com/mingster/dotfiles/issues)!

## Author
Ming Tsai

(modifided from Mathias's dotfiles - https://github.com/mathiasbynens/dotfiles)

## Thanks to…

* @ptb and [his _OS X Lion Setup_ repository](https://github.com/ptb/Mac-OS-X-Lion-Setup)
* [Ben Alman](http://benalman.com/) and his [dotfiles repository](https://github.com/cowboy/dotfiles)
* [Chris Gerke](http://www.randomsquared.com/) and his [tutorial on creating an OS X SOE master image](http://chris-gerke.blogspot.com/2012/04/mac-osx-soe-master-image-day-7.html) + [_Insta_ repository](https://github.com/cgerke/Insta)
* [Cãtãlin Mariş](https://github.com/alrra) and his [dotfiles repository](https://github.com/alrra/dotfiles)
* [Gianni Chiappetta](http://gf3.ca/) for sharing his [amazing collection of dotfiles](https://github.com/gf3/dotfiles)
* [Jan Moesen](http://jan.moesen.nu/) and his [ancient `.bash_profile`](https://gist.github.com/1156154) + [shiny _tilde_ repository](https://github.com/janmoesen/tilde)
* [Lauri ‘Lri’ Ranta](http://lri.me/) for sharing [loads of hidden preferences](http://osxnotes.net/defaults.html)
* [Matijs Brinkhuis](http://hotfusion.nl/) and his [dotfiles repository](https://github.com/matijs/dotfiles)
* [Nicolas Gallagher](http://nicolasgallagher.com/) and his [dotfiles repository](https://github.com/necolas/dotfiles)
* [Sindre Sorhus](http://sindresorhus.com/)
* [Tom Ryder](http://blog.sanctum.geek.nz/) and his [dotfiles repository](https://github.com/tejr/dotfiles)
* [Kevin Suttle](http://kevinsuttle.com/) and his [dotfiles repository](https://github.com/kevinSuttle/dotfiles) and [OSXDefaults project](https://github.com/kevinSuttle/OSXDefaults), which aims to provide better documentation for [`~/.osx`](http://mths.be/osx)
* [Haralan Dobrev](http://hkdobrev.com/)

* anyone who [contributed a patch](https://github.com/mathiasbynens/dotfiles/contributors) or [made a helpful suggestion](https://github.com/mathiasbynens/dotfiles/issues)
