#!/usr/bin/env bash
# Install AWS CLI v2 (cross-platform).
# Docs: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
set -euo pipefail

if command -v aws >/dev/null 2>&1; then
  echo "install_aws_cli: already installed ($(aws --version 2>&1 | head -1))"
  exit 0
fi

# Downloads go to a private folder, removed on success and on failure.
aws_tmp=""
trap '[ -z "$aws_tmp" ] || rm -rf "$aws_tmp"' EXIT

if command -v brew >/dev/null 2>&1; then
  if [ "$(uname -m)" = "x86_64" ]; then
    aws_tmp=$(mktemp -d "${TMPDIR:-/tmp}/install_aws_cli.XXXXXX")
    curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$aws_tmp/AWSCLIV2.pkg"
    sudo installer -pkg "$aws_tmp/AWSCLIV2.pkg" -target /
  else
    brew install awscli
  fi
elif command -v yay >/dev/null 2>&1; then
  yay -S --noconfirm --needed aws-cli-v2
else
  # Debian / Raspberry Pi OS / generic Linux
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  AWS_ARCH="x86_64" ;;
    aarch64) AWS_ARCH="aarch64" ;;
    *)
      echo "install_aws_cli: unsupported architecture $ARCH" >&2
      exit 1
      ;;
  esac
  if ! command -v unzip >/dev/null 2>&1; then
    echo "install_aws_cli: unzip is required (sudo apt-get install unzip)" >&2
    exit 1
  fi
  aws_tmp=$(mktemp -d "${TMPDIR:-/tmp}/install_aws_cli.XXXXXX")
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "$aws_tmp/awscliv2.zip"
  unzip -q "$aws_tmp/awscliv2.zip" -d "$aws_tmp/awscliv2"
  sudo "$aws_tmp/awscliv2/aws/install"
fi

echo "install_aws_cli: ok ($(aws --version 2>&1 | head -1))"
