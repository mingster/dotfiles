#!/usr/bin/env bash
# Sourced by tests that commit in throwaway repos. Puts the identity in a gitconfig file inside the
# test's temp dir and points GIT_CONFIG_GLOBAL at it, so no GIT_AUTHOR_* or GIT_COMMITTER_* variable
# is ever exported (#844). Usage: use_test_git_identity <temp dir>
use_test_git_identity() {
  local cfg="$1/gitconfig-test"
  git config --file "$cfg" user.name t
  git config --file "$cfg" user.email t@t
  export GIT_CONFIG_GLOBAL="$cfg" GIT_CONFIG_NOSYSTEM=1
}
