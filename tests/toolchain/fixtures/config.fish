# ~/.config/fish/config.fish of the fixture user: 79 lines, none of them the wiring.
# Contract #119 copies this file into the fake home; no test runs it.

# no greeting
set -g fish_greeting

# editor and pager
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx PAGER less
set -gx LESS -FRX
set -gx MANPAGER 'nvim +Man!'

# locale
set -gx LANG en_US.UTF-8
set -gx LC_TIME de_DE.UTF-8

# paths
fish_add_path --global $HOME/.local/bin
fish_add_path --global $HOME/go/bin
fish_add_path --global $HOME/.bun/bin

# history
set -g fish_history default
set -g fish_color_command blue
set -g fish_color_param normal
set -g fish_color_error red --bold
set -g fish_color_comment brblack

# go
set -gx GOPATH $HOME/go
set -gx GOFLAGS -trimpath

# node
set -gx NVM_DIR $HOME/.nvm

# python
set -gx PYTHONDONTWRITEBYTECODE 1
set -gx PIP_REQUIRE_VIRTUALENV true

if status is-interactive
    # git
    abbr --add g git
    abbr --add gs 'git status --short'
    abbr --add gd 'git diff'
    abbr --add gl 'git log --oneline -20'
    abbr --add gp 'git push'

    # files
    abbr --add l 'ls -lah'
    abbr --add t 'tree -L 2'
    abbr --add .. 'cd ..'

    # packages
    abbr --add pacs 'pacman -Ss'
    abbr --add paci 'pacman -Qi'

    # keys
    bind \cg 'commandline -f cancel'
end

# make a directory and enter it
function mkcd --description 'mkdir -p, then cd'
    mkdir -p $argv[1]
    and cd $argv[1]
end

# the newest files of a directory
function newest --description 'the ten newest entries'
    ls -t $argv | head -n 10
end

# seconds since the epoch, for prompts and logs
function now
    date +%s
end

# a slower key repeat makes vi mode usable over ssh
set -g fish_escape_delay_ms 30
