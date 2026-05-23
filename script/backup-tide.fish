#!/usr/bin/env fish
# Save current tide universal variables to dotfiles for restore on new machines.
# Run this after configuring tide, then commit the result.

set dest ~/dotfiles/.config/fish/tide_config.fish

printf '' > $dest

set count 0
for line in (set --universal | string match -r '^tide_.*')
    set var (string split ' ' $line)[1]
    set vals $$var
    set escaped (string escape -- $vals)
    echo "set -U $var $escaped" >> $dest
    set count (math $count + 1)
end

echo "backup-tide: saved $count variables to $dest"
