#!/usr/bin/env bash
# Install Google Cloud CLI (cross-platform).
# Docs: https://cloud.google.com/sdk/docs/install
set -euo pipefail

if command -v gcloud >/dev/null 2>&1; then
  echo "install_gcloud: already installed ($(gcloud --version 2>/dev/null | head -1))"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  brew list --cask google-cloud-sdk >/dev/null 2>&1 || brew install --cask google-cloud-sdk
elif command -v yay >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    yay -S --noconfirm --needed google-cloud-cli
  else
    echo "install_gcloud: sudo not available — skipping google-cloud-cli install" >&2
    exit 0
  fi
else
  # Debian / Raspberry Pi OS / generic Linux — use official apt repo
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
  sudo apt-get update
  sudo apt-get install -y google-cloud-cli
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "install_gcloud: gcloud not on PATH after install." >&2
  echo "  Restart your shell or add the SDK bin directory to PATH." >&2
  exit 1
fi

echo "install_gcloud: ok ($(gcloud --version 2>/dev/null | head -1))"
