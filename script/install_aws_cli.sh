#!/usr/bin/env bash
# Install AWS CLI v2 (cross-platform).
# Docs: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
set -euo pipefail

if command -v aws >/dev/null 2>&1; then
  echo "install_aws_cli: already installed ($(aws --version 2>&1 | head -1))"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  if [ "$(uname -m)" = "x86_64" ]; then
    curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
    sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
    rm -f /tmp/AWSCLIV2.pkg
  else
    brew install awscli
  fi
elif command -v yay >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    yay -S --noconfirm --needed aws-cli-v2
  else
    echo "install_aws_cli: sudo not available — skipping aws-cli-v2 install" >&2
    exit 0
  fi
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
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
  sudo /tmp/awscliv2/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/awscliv2
fi

echo "install_aws_cli: ok ($(aws --version 2>&1 | head -1))"
