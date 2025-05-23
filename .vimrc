colorscheme solarized

if !exists("g:syntax_on")
    syntax enable
    filetype on
endif

"set number

" Use Vim instead of vi. This must be first because it changes other options
" as a side effect.
set nocompatible

" Allows Vim to manage multiple buffers effectively. The current buffer can be
" put to the background without writing to disk. When a background buffer
" becomes current again, marks and undo-history are remembered.
"
" http://items.sjbach.com/319/configuring-vim-right
set hidden

let mapleader=","

" === Init Vundle ===
"
" Loads all plugins specified in ~/.vim/vundle.vim
if filereadable(expand("~/.vim/vundle.vim"))
    source ~/.vim/vundle.vim
endif

" === Scrolling ===
set scrolloff=8         " Start scrolling when we're 8 lines away from margins.
set sidescrolloff=15
set sidescroll=1

" === Completion ===
set wildmode=list:longest
set wildmenu                    " Enable ctrl-n and ctrl-p to scroll thru matches.
set wildignore=*.o,*.obj,*~     " Stuff to ignore when tab completing.
set wildignore+=*sass-cache*
set wildignore+=*DS_Store*
set wildignore+=vendor/cache/**
set wildignore+=log/**
set wildignore+=tmp/**
set wildignore+=*.png,*.jpg,*.gif

" === fzf intergration ===
"set rtp+=/usr/local/opt/fzf
set rtp+=/opt/homebrew/opt/fzf
