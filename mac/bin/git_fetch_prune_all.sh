#!/bin/bash

# Run git fetch --prune for all git repositories in ~/GitHub
# Works on both Intel and ARM Mac architectures

# Set Homebrew path based on architecture so gh credential helper is found
if [ "$(uname -m)" = "arm64" ]; then
    export PATH="/opt/homebrew/bin:$PATH"
else
    export PATH="/usr/local/bin:$PATH"
fi

GITHUB_DIR="$HOME/GitHub"

# Check if GitHub directory exists
if [ ! -d "$GITHUB_DIR" ]; then
    echo "Error: $GITHUB_DIR does not exist"
    exit 1
fi

fetch_if_git() {
    if [ -d "$1/.git" ]; then
        echo "Fetching: $1"
        git -C "$1" fetch --prune
        git -C "$1" gc
    fi
}

# Iterate through top-level directories
for dir in "$GITHUB_DIR"/*/; do
    # Remove trailing slash for cleaner output
    dir="${dir%/}"

    if [ -d "$dir/.git" ]; then
        # Direct git repo
        fetch_if_git "$dir"
    else
        # Check subdirectories (nested repos)
        for subdir in "$dir"/*/; do
            subdir="${subdir%/}"
            [ -d "$subdir" ] && fetch_if_git "$subdir"
        done
    fi
done

PROJECT_DIR="$HOME/projects"

# Iterate through top-level directories
for dir in "$PROJECT_DIR"/*/; do
    # Remove trailing slash for cleaner output
    dir="${dir%/}"

    if [ -d "$dir/.git" ]; then
        # Direct git repo
        fetch_if_git "$dir"
    else
        # Check subdirectories (nested repos)
        for subdir in "$dir"/*/; do
            subdir="${subdir%/}"
            [ -d "$subdir" ] && fetch_if_git "$subdir"
        done
    fi
done
