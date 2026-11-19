# Environment for every zsh. Machine specific or private lines go in ~/.zshenv.local.
export BUN_FEATURE_FLAG_DISABLE_IPV6=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_CASK_OPTS="--appdir=/Applications/_dev"
export npm_config_prefix="$HOME/.node_modules"
for d in "$HOME/.node_modules/bin" "$HOME/.yarn/bin" "$HOME/.grok/bin" "$HOME/.antigravity-ide/antigravity-ide/bin"; do
  [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

[ -f "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
