#!/usr/bin/env bash

echo '---- install aws cli ----'

if ! command -v aws >/dev/null 2>&1; then
    architecture=$(uname -m)
    if [ "$architecture" == "arm64" ]; then
      brew install awscli
    elif [ "$architecture" == "x86_64" ]; then
        #echo "This Mac is using Intel."
        curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
        sudo installer -pkg AWSCLIV2.pkg -target /
        rm AWSCLIV2.pkg
    else
        echo "Unknown architecture: $architecture"
    fi
else
    echo "aws cli is already installed"
    whereis aws
    aws --version
fi
