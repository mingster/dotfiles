#!/usr/bin/env bash
# Install Ollama and pull Gemma models. Model tier is chosen by available memory/VRAM:
#   >= 16 GB  →  gemma4:26b
#   >=  8 GB  →  gemma4:12b
#   <   8 GB  →  gemma4:e4b
# Docs: https://ollama.com
set -euo pipefail

# --- guard: Apple Silicon only on macOS ---

if [[ "${OSTYPE:-}" = darwin* ]]; then
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" -ne 1 ]; then
    echo "install_ollama: Ollama is only supported on ARM-based macOS (Apple Silicon). Skipping."
    exit 0
  fi
fi

# --- detect available memory/VRAM ---
# Done early — used for both service tuning and model selection.

_available_gb() {
  local mem_gb=0
  case "${OSTYPE:-}" in
    darwin*)
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

# --- install ollama ---

_install_ollama_macos() {
  [ -d "/Applications/Ollama.app" ] && return 0
  local latest zip
  latest=$(curl -fsSL "https://api.github.com/repos/ollama/ollama/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
  zip="/tmp/Ollama-darwin.zip"
  echo "install_ollama: downloading Ollama ${latest} from github.com/ollama/ollama"
  curl -fSL "https://github.com/ollama/ollama/releases/download/v${latest}/Ollama-darwin.zip" -o "$zip"
  unzip -q -o "$zip" -d /Applications
  rm -f "$zip"
  # Expose the CLI binary on PATH
  ln -sf /Applications/Ollama.app/Contents/Resources/ollama /usr/local/bin/ollama 2>/dev/null \
    || sudo ln -sf /Applications/Ollama.app/Contents/Resources/ollama /usr/local/bin/ollama
}

if ! command -v ollama >/dev/null 2>&1; then
  case "${OSTYPE:-}" in
    darwin*)
      _install_ollama_macos
      ;;
    *)
      if command -v yay >/dev/null 2>&1; then
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
      ;;
  esac
else
  echo "install_ollama: already installed ($(ollama --version 2>/dev/null || echo ok))"
fi

# --- configure service and start ---

_num_threads() {
  case "${OSTYPE:-}" in
    darwin*) sysctl -n hw.logicalcpu ;;
    linux*)  nproc ;;
    *)       echo 4 ;;
  esac
}

_parallel_from_mem() {
  if [ "$MEM_GB" -ge 32 ]; then echo 4
  elif [ "$MEM_GB" -ge 16 ]; then echo 2
  else echo 1
  fi
}

NUM_THREADS=$(_num_threads)
NUM_PARALLEL=$(_parallel_from_mem)

echo "install_ollama: configuring service (threads=${NUM_THREADS}, parallel=${NUM_PARALLEL}, host=0.0.0.0:11434)"

case "${OSTYPE:-}" in
  darwin*)
    # Create a custom LaunchAgent that runs `ollama serve` with env vars baked in.
    # This works for both the cask (Ollama.app) and the formula install.
    PLIST="$HOME/Library/LaunchAgents/com.ollama.server.plist"
    OLLAMA_BIN=$(command -v ollama)
    python3 - "$PLIST" "$OLLAMA_BIN" "$NUM_THREADS" "$NUM_PARALLEL" <<'PYEOF'
import sys, plistlib
path, binary, threads, parallel = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
plist = {
    'Label': 'com.ollama.server',
    'ProgramArguments': [binary, 'serve'],
    'EnvironmentVariables': {
        'OLLAMA_NUM_PARALLEL': parallel,
        'OLLAMA_NUM_THREADS': threads,
        'OLLAMA_KEEP_ALIVE': '24h',
        'OLLAMA_HOST': '0.0.0.0:11434',
        'OLLAMA_ORIGINS': '*',
    },
    'RunAtLoad': True,
    'KeepAlive': True,
    'StandardOutPath': '/tmp/ollama.log',
    'StandardErrorPath': '/tmp/ollama.log',
}
with open(path, 'wb') as f:
    plistlib.dump(plist, f, fmt=plistlib.FMT_XML)
PYEOF
    # Unload any prior version, then load the updated plist.
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    ;;
  linux*)
    DROP_IN="/etc/systemd/system/ollama.service.d"
    sudo mkdir -p "$DROP_IN"
    sudo tee "$DROP_IN/override.conf" > /dev/null <<EOF
[Service]
Environment="OLLAMA_NUM_PARALLEL=${NUM_PARALLEL}"
Environment="OLLAMA_NUM_THREADS=${NUM_THREADS}"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_ORIGINS=*"
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now ollama 2>/dev/null || true
    ;;
esac

# --- wait for daemon ---

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

# --- select and pull model ---

if [ "$MEM_GB" -ge 16 ]; then
  MODEL="gemma4:26b"
elif [ "$MEM_GB" -ge 8 ]; then
  MODEL="gemma4:12b"
else
  MODEL="gemma4:e4b"
fi

echo "install_ollama: ${MEM_GB} GB detected → ${MODEL}"

if ollama list 2>/dev/null | grep -q "^${MODEL}"; then
  echo "install_ollama: ${MODEL} already pulled"
else
  ollama pull "${MODEL}"
fi

echo "install_ollama: ok — run: ollama run ${MODEL}"
