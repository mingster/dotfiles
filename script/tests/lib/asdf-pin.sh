#!/usr/bin/env bash
# Sourced by tests that change HOME. The asdf shims read ~/.tool-versions, which a temp HOME
# does not have, so pin the interpreters from the repo's .tool-versions first.
# Also pins ASDF_DATA_DIR, which asdf otherwise derives from HOME and loses with a temp HOME.
# Keeps any ASDF_* value that is already set. Pure bash.
_asdf_pin_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)/.tool-versions"
if [ -r "$_asdf_pin_file" ]; then
  while read -r _asdf_pin_tool _asdf_pin_version _; do
    case "$_asdf_pin_tool" in
      python) [ -n "${ASDF_PYTHON_VERSION:-}" ] || export ASDF_PYTHON_VERSION="$_asdf_pin_version" ;;
      nodejs) [ -n "${ASDF_NODEJS_VERSION:-}" ] || export ASDF_NODEJS_VERSION="$_asdf_pin_version" ;;
    esac
  done < "$_asdf_pin_file"
fi
[ -n "${ASDF_DATA_DIR:-}" ] || [ ! -d "${HOME:-}/.asdf" ] || export ASDF_DATA_DIR="$HOME/.asdf"
unset _asdf_pin_file _asdf_pin_tool _asdf_pin_version
