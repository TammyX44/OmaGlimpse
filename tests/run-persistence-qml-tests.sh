#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
shell_dir=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}
stage=$(mktemp -d /tmp/omaglimpse-persistence-tests.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/fixtures" "$stage/config" "$stage/cache" "$stage/state"
ln -s "$shell_dir/Commons" "$stage/Commons"
ln -s "$shell_dir/Ui" "$stage/Ui"
# Snapshot sources so concurrent main edits cannot change a running fixture.
for file in "$repo"/*.qml "$repo"/*.js "$repo"/*.sh "$repo"/*.py; do
  [ ! -f "$file" ] || cp "$file" "$stage/${file##*/}"
done
cp "$repo/tests/persistence-ui-smoke.qml" "$stage/shell.qml"
# Optional before-fix comparison; extracts only into the disposable stage.
if [ -n "${PERSISTENCE_TEST_REF:-}" ]; then
  git -C "$repo" archive "$PERSISTENCE_TEST_REF" Widgets.qml | tar -x -C "$stage"
fi
status=0
PERSISTENCE_TEST_DIR="$stage/fixtures" XDG_CONFIG_HOME="$stage/config" \
  XDG_CACHE_HOME="$stage/cache" XDG_STATE_HOME="$stage/state" \
  QT_QPA_PLATFORM=wayland QT_QPA_PLATFORMTHEME=basic QT_QUICK_BACKEND=software \
  timeout --kill-after=2s 30s qs --no-color -p "$stage/shell.qml" > "$stage/result.log" 2>&1 || status=$?
cat "$stage/result.log"
if [ "$status" != 0 ] || ! rg -q 'PERSISTENCE_UI_TOTAL 2 passed, 0 failed' "$stage/result.log" \
    || rg -q 'FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop' "$stage/result.log"; then
  exit 1
fi
