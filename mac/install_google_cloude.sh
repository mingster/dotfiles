#!/usr/bin/env bash

echo '---- install google cloud cli ----'

if ! command -v gcloud >/dev/null 2>&1; then
    architecture=$(uname -m)
    if [ "$architecture" == "arm64" ]; then
        echo "This Mac is using Apple Silicon."
    elif [ "$architecture" == "x86_64" ]; then
        echo "This Mac is using Intel."
    else
        echo "Unknown architecture: $architecture"
    fi

      brew update && brew install --cask gcloud-cli

else
    echo "gcloud is already installed"
    whereis gcloud
    gcloud --version
fi
