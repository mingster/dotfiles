#!/usr/bin/env bash
# install-agent-clis.sh tests. Usage (#1588): --help and bad arguments install nothing and touch no rc file.
# Rc handling (#1542): a tracked rc is restored after a vendor append, an unexpected tracked edit fails,
# an untracked rc is reported, and install_claude.sh skips the installer when claude is already on PATH.
# Each case has a temp HOME, a temp git checkout as DOTFILES and stub curl/agy/grok (claude is added by
# the installer payload, or put on PATH only for the already-installed case). No network.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$(dirname "$0")/lib/asdf-pin.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tests=0

mkdir "$work/bin" "$work/home"
for stub in curl claude agy grok; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$stub" "$work" > "$work/bin/$stub"
  chmod +x "$work/bin/$stub"
done
: > "$work/calls"
printf 'original\n' > "$work/home/.zshrc"

run() { # <args...>: sets out, err, ec
  ec=0
  HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" bash "$root/script/install-agent-clis.sh" "$@" \
    >"$work/out" 2>"$work/err" || ec=$?
}

check() { # <label> <condition exit status>
  if [[ $2 != 0 ]]; then
    printf 'FAIL: %s\n  stdout: %s\n  stderr: %s\n' "$1" "$(cat "$work/out")" "$(cat "$work/err")" >&2
    exit 1
  fi
  tests=$((tests + 1))
}

for flag in -h --help; do
  run "$flag"
  check "$flag exits 0" "$ec"
  check "$flag prints Usage:" "$(grep -q '^Usage:' "$work/out"; echo $?)"
  check "$flag calls no stub" "$([[ ! -s $work/calls ]]; echo $?)"
  check "$flag leaves rc file" "$([[ $(cat "$work/home/.zshrc") == original ]]; echo $?)"
done
for bad in --bogus --dry-run extra; do
  run "$bad"
  check "$bad exits 2" "$([[ $ec == 2 ]]; echo $?)"
  check "$bad prints Usage: on stderr" "$(grep -q '^Usage:' "$work/err"; echo $?)"
  check "$bad calls no stub" "$([[ ! -s $work/calls ]]; echo $?)"
done
run --help extra
check "--help with more arguments exits 2" "$([[ $ec == 2 ]]; echo $?)"

# Rc cases. Each case dir holds bin/ (stubs), home/ (.zshrc symlinked into the checkout) and
# dotfiles/ (a git checkout whose index tracks .zshrc). The stub curl prints <case>/payload, which
# the installer runs as the vendor installer.
new_case() { # <case dir>
  local d=$1
  mkdir -p "$d/bin" "$d/home" "$d/dotfiles/script"
  cp "$root/script/install_claude.sh" "$d/dotfiles/script/"
  printf 'original\n' > "$d/dotfiles/.zshrc"
  git -C "$d/dotfiles" init -q
  git -C "$d/dotfiles" add .zshrc
  ln -s "$d/dotfiles/.zshrc" "$d/home/.zshrc"
  printf '#!/usr/bin/env bash\necho "curl $*" >> "%s/calls"\ncat "%s/payload"\n' "$d" "$d" > "$d/bin/curl"
  for stub in agy grok; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$stub" "$d" > "$d/bin/$stub"
  done
  chmod +x "$d/bin"/*
  : > "$d/calls"
}

write_payload() { # <case dir> <shell lines...>: installs a claude on PATH, then runs the lines
  local d=$1
  shift
  {
    echo 'mkdir -p "$HOME/.local/bin"'
    echo 'printf "#!/usr/bin/env bash\necho claude 1.0\n" > "$HOME/.local/bin/claude"'
    echo 'chmod +x "$HOME/.local/bin/claude"'
    printf '%s\n' "$@"
  } > "$d/payload"
}

run_installer() { # <case dir>: sets out, err, ec. PATH is the stub dir plus /usr/bin (git, python3); no host bin dirs.
  local d=$1
  ec=0
  env -u ZDOTDIR -u ASDF_DATA_DIR HOME="$d/home" DOTFILES="$d/dotfiles" \
    PATH="$d/bin:/usr/bin:/bin" \
    bash "$root/script/install-agent-clis.sh" >"$work/out" 2>"$work/err" || ec=$?
}

# Vendor appends to a tracked rc: the rc is restored to its original bytes.
new_case "$work/append"
write_payload "$work/append" 'printf "export VENDOR_PATH=1\n" >> "$HOME/.zshrc"'
run_installer "$work/append"
check "append: exits 0" "$ec"
check "append: prints restore message" \
  "$(grep -q '^install-agent-clis: removed vendor additions from tracked rc' "$work/out"; echo $?)"
check "append: tracked rc has original bytes" \
  "$(printf 'original\n' | cmp -s - "$work/append/dotfiles/.zshrc"; echo $?)"
check "append: home rc is still a symlink" "$([[ -L $work/append/home/.zshrc ]]; echo $?)"

# Vendor overwrites a tracked rc with bytes that do not start with the original: fail, do not restore.
new_case "$work/overwrite"
write_payload "$work/overwrite" 'printf "replaced\n" > "$HOME/.zshrc"'
run_installer "$work/overwrite"
check "overwrite: exits non-zero" "$([[ $ec != 0 ]]; echo $?)"
check "overwrite: reports unexpected rc edit on stderr" \
  "$(grep -q '^install-agent-clis: unexpected rc edit' "$work/err"; echo $?)"

# Vendor replaces the symlink with a regular file that starts with the original bytes: the symlink check fails it.
new_case "$work/symlink"
write_payload "$work/symlink" 'rm "$HOME/.zshrc"' 'printf "original\nVENDOR\n" > "$HOME/.zshrc"'
run_installer "$work/symlink"
check "replaced symlink: exits non-zero" "$([[ $ec != 0 ]]; echo $?)"
check "replaced symlink: reports unexpected rc edit on stderr" \
  "$(grep -q '^install-agent-clis: unexpected rc edit' "$work/err"; echo $?)"

# Vendor touches an rc outside dotfiles: report it and still exit 0.
new_case "$work/untracked"
write_payload "$work/untracked" 'printf "export VENDOR=1\n" >> "$HOME/.bashrc"'
run_installer "$work/untracked"
check "untracked: exits 0" "$ec"
check "untracked: reports the untracked rc" \
  "$(grep -q '^install-agent-clis: vendor touched untracked rc outside dotfiles:' "$work/out"; echo $?)"
check "untracked: tracked rc unchanged" \
  "$(printf 'original\n' | cmp -s - "$work/untracked/dotfiles/.zshrc"; echo $?)"

# claude already on PATH: install_claude.sh exits 0 and never runs the curl installer.
new_case "$work/preinstalled"
printf '#!/usr/bin/env bash\necho "claude $*" >> "%s/calls"\n' "$work/preinstalled" > "$work/preinstalled/bin/claude"
chmod +x "$work/preinstalled/bin/claude"
ec=0
env -u ZDOTDIR HOME="$work/preinstalled/home" PATH="$work/preinstalled/bin:/usr/bin:/bin" \
  bash "$root/script/install_claude.sh" >"$work/out" 2>"$work/err" || ec=$?
check "claude on PATH: install_claude exits 0" "$ec"
check "claude on PATH: reports already in PATH" \
  "$(grep -q '^install_claude: claude already in PATH' "$work/out"; echo $?)"
check "claude on PATH: no curl call" "$(! grep -q '^curl' "$work/preinstalled/calls"; echo $?)"

printf 'PASS: %s tests\n' "$tests"
