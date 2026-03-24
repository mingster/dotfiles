#!/bin/sh

# Run git fetch --prune for all git repositories in ~/GitHub

GITHUB_DIR="$HOME/GitHub"

fetch_if_git() {
    if [ -d "$1/.git" ]; then
        echo "Fetching: $1"
        git -C "$1" fetch --prune
    fi
}

for dir in "$GITHUB_DIR"/*/; do
    if [ -d "$dir/.git" ]; then
        fetch_if_git "$dir"
    else
        for subdir in "$dir"*/; do
            fetch_if_git "$subdir"
        done
    fi
done
