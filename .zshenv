# Environment for every zsh. Machine specific or private lines go in ~/.zshenv.local.
export BUN_FEATURE_FLAG_DISABLE_IPV6=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export npm_config_prefix="$HOME/.node_modules"
for d in "$HOME/.node_modules/bin" "$HOME/.yarn/bin" "$HOME/.grok/bin" "$HOME/.antigravity-ide/antigravity-ide/bin"; do
  [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

# Tell tools the terminal does 24 bit color. Kitty and its peers reach us over ssh with TERM set but no COLORTERM.
if [ -z "${COLORTERM:-}" ]; then
  case "${TERM:-}:${TERM_PROGRAM:-}" in
    *kitty*|*ghostty*|*[Ww]ez[Tt]erm*|*iTerm*|*alacritty*|*Alacritty*) export COLORTERM=truecolor ;;
  esac
fi

[ -f "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
