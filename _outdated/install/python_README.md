# Python virtual environments with asdf, venv and direnv
How to use common tooling to manage your Python virtual environments

## PYTHONSHELL

Every language and its community seems to have its own story (and at times drama) on how to handle dependencies. We even have a conference just to talk about it. In Python, isolating dependencies and interpreter versions (together known as a "virtual environment") is notorious for tripping up beginners just getting started. The Python community understands this but is still deciding on a solution. Since Python is not my main daily language, I tend to forget about virtual environments for months at a time. This post is mostly for me to remember how I do it each time, but it's simple enough and uses familiar tooling that I hope it helps someone else.

In Python 3.3, the venv module got added natively to the default Python interpreter. This is the main workhorse between virtual environments and by learning a little about how it works, we can have a simple workflow to automatically create virtual environments when we cd into a project directory. The three main tools involved are asdf, venv (the module), and direnv.

## Overview on each tool

### asdf 
is a generic version manager for almost all of the popular language runtimes. Alongside python, I use it to manage my golang, nodejs and perl installations. One package manager to rule them all.

### direnv 

allows you to change your shell's environment based on which current directory your shell session lives in. There are some neat features tucked into this tool so I suggest you dive into their documentation.

As you soon will see, you use the venv module to actually create the virtual environment. Once that happens, you'll have access to executables that can be used to activate these virtual environments. Since all .venv/bin/activate does is change the shell's environment variables, we skip right over using it and change the environment the same way with direnv.

## My simple workflow

Change into (or create) your project directory:

``` shell
cd /the/path/to/your/project
```

``` shell
asdf plugin add python
```

``` shell
asdf install python 3.10.0
```

``` shell
asdf local python 3.10.0
```

Start by creating the virtual environment:

``` shell
python -m venv .venv
```

Then create an .envrc (what direnv looks for) to set relevant PATH vars for the right executables to be picked up:

``` shell
echo "export VIRTUAL_ENV=$PWD/.venv\nexport PATH=$PWD/.venv/bin:\$PATH" > .envrc
```

I'm pretty sure VIRTUAL_ENV isn't necessary to be set but since explicit activation does it, there's no harm. Direnv should then warn you that these new environment variables are going to be loaded. To continue,

``` shell
direnv allow
```

Activate the venv

``` shell
source .venv/bin/activate
```

That should be it! To confirm that python and pip are pointing to the right places:

``` shell
which python
```

/the/path/to/your/project/.venv/bin/python3

``` shell
which pip
```

/the/path/to/your/project/.venv/bin/pip


### start coding
``` shell
pip install -r requirements.txt
```


## Ref
- [Local Development Environments for Python using asdf & Poetry](https://dev.to/ralaruri/local-development-environments-for-python-using-asdf-poetry-1d9l)