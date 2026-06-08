#!/usr/bin/env bash
# Install Ollama and pull Gemma 3. Model tier is chosen by available memory/VRAM:
#   >= 12 GB  →  gemma3:12b  (~8.1 GB)
#   >=  5 GB  →  gemma3:4b   (~3.3 GB)
#   <   5 GB  →  gemma3:2b   (~1.6 GB)
# Docs: https://ollama.com
set -euo pipefail

# --- install ollama ---

# Only install Ollama on ARM-based macOS (Apple Silicon).
# Explicitly skip on Intel macOS.
if [[ "${OSTYPE:-}" = darwin* ]]; then
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" -ne 1 ]; then
    echo "install_ollama: Ollama is only supported on ARM-based macOS (Apple Silicon). Skipping."
    exit 0
  fi
fi

if ! command -v ollama >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "install_ollama: brew install ollama"
    brew list ollama >/dev/null 2>&1 || brew install ollama
  elif command -v yay >/dev/null 2>&1; then
    # Use the CUDA build when an NVIDIA GPU is present
    if command -v nvidia-smi >/dev/null 2>&1; then
      echo "install_ollama: yay -S ollama-cuda (NVIDIA detected)"
      yay -S --noconfirm --needed ollama-cuda
    else
      echo "install_ollama: yay -S ollama"
      yay -S --noconfirm --needed ollama
    fi
  else
    echo "install_ollama: using https://ollama.com/install.sh"
    curl -fsSL https://ollama.com/install.sh | sh
  fi
else
  echo "install_ollama: already installed ($(ollama --version 2>/dev/null || echo ok))"
fi

# --- start service ---

case "${OSTYPE:-}" in
  darwin*)
    brew services start ollama 2>/dev/null || true
    ;;
  linux*)
    sudo systemctl enable --now ollama 2>/dev/null || true
    ;;
esac

# Wait for the daemon to be ready (up to 30 s)
_wait_ready() {
  local i=0
  while [ "$i" -lt 30 ]; do
    ollama list >/dev/null 2>&1 && return 0
    sleep 1
    i=$(( i + 1 ))
  done
  echo "install_ollama: timed out waiting for daemon" >&2
  return 1
}
_wait_ready

# --- detect available memory/VRAM ---

_available_gb() {
  local mem_gb=0
  case "${OSTYPE:-}" in
    darwin*)
      # Apple Silicon: unified memory is both RAM and VRAM
      local mem_bytes
      mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
      mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
      ;;
    linux*)
      local mem_kb
      mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
      mem_gb=$(( mem_kb / 1024 / 1024 ))
      # Prefer NVIDIA VRAM when available
      if command -v nvidia-smi >/dev/null 2>&1; then
        local vram_mb vram_gb
        vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        vram_gb=$(( vram_mb / 1024 ))
        [ "$vram_gb" -gt "$mem_gb" ] && mem_gb=$vram_gb
      fi
      ;;
  esac
  echo "$mem_gb"
}

MEM_GB=$(_available_gb)

if [ "$MEM_GB" -ge 12 ]; then
  MODEL="gemma3:12b"
elif [ "$MEM_GB" -ge 5 ]; then
  MODEL="gemma3:4b"
else
  MODEL="gemma3:2b"
fi

echo "install_ollama: ${MEM_GB} GB detected → ${MODEL}"

# --- pull model if not already present ---

if ollama list 2>/dev/null | grep -q "^${MODEL}"; then
  echo "install_ollama: ${MODEL} already pulled"
else
  ollama pull "${MODEL}"
fi

echo "install_ollama: ok — run: ollama run ${MODEL}"
oa
