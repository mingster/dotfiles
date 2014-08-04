# Ming's dotfiles
DotFiles allows you quickly set up enviornment on a newly installed OSX. Check <a href="http://dotfiles.github.io">this
</a> out if you're not familar with it.

My dotfiles is based on the <a href="https://github.com/mathiasbynens/dotfiles">Mathias’s legendary dotfiles</a>, a couple
changes are added to my favourites:

1. .osx script: updates to my accustomed looks/feel & settings.
2. add python development setup



## Install Xcode and its "Command Line Tools"

- Go to App Store and install Xcode.
- Open and accept the terms
- Then go to the terminal and install "Command Line Tools":

```bash
xcode-select --install
```


## Installation - Brew
Open up Terminal, install brew:
```bash
./brew
```
This will install brew, git, and iTerm2


## DotFiles Installation

### Using Git and the bootstrap script

Open up iTerm2, you can now using git to clone down this repository.
You can clone the repository wherever you want.
(I like to keep it in `~/GitHub/dotfiles`,
with `~/dotfiles` as a symlink.)

```bash
git clone https://github.com/mingster/mingster-dotfiles.git && cd mingster-dotfiles
```

### Review & update your info
  - review .extra and replace it with your info


### Install it
To execute, `cd` into your local `dotfiles` repository and then:
```bash
source bootstrap.sh
```

The bootstrapper script will pull in the latest version and copy the files to
your home folder.

To update later on, just run that command again.

Exit out iTerm2 and re-open it, you should see the different.


## Sensible OS X defaults

When setting up a new Mac, you may want to set some sensible OS X defaults.  Review it carefully to best suit your own
preferences.  To execute:

```bash
./.osx
```

## Install Additional Homebrew formulaes

When setting up a new Mac, you may want to install some common
[Homebrew](http://brew.sh/) formulae.

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
[welcome](https://github.com/mingster/mingster-dotfiles/issues)!

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

* anyone who [contributed a patch](https://github.com/mingster/mingster-dotfiles/contributors) or [made a helpful suggestion](https://github.com/mingster/mingster-dotfiles/issues)
