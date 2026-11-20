# shellcheck shell=sh
# The one place that knows where a Mac app can live. Apps belong in /Applications; the old
# per-category folder is still searched second because some hosts have not moved their apps yet.
# Every script that needs an app path sources this file and calls app_path, so nothing else
# spells the folder out (script/check-appdir.sh enforces it).
# APP_PATH_DIRS (space separated, most preferred first) is only for tests.
#
#   app_path Orca.app   prints the first existing /Applications/Orca.app, else the old folder's,
#                       else /Applications/Orca.app (where a fresh install lands). Always exit 0.
APP_DIRS=${APP_PATH_DIRS:-"/Applications /Applications/_dev"}

app_path() {
  for _app_dir in $APP_DIRS; do
    if [ -e "$_app_dir/$1" ]; then
      printf '%s\n' "$_app_dir/$1"
      return 0
    fi
  done
  printf '%s/%s\n' "${APP_DIRS%% *}" "$1"
}
