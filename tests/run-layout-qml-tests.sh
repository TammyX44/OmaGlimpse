#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
shell_dir=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}
stage=$(mktemp -d /tmp/omaglimpse-layout-tests.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/runtime"
chmod 700 "$stage/runtime"
ln -s "$shell_dir/Commons" "$stage/Commons"
ln -s "$shell_dir/Ui" "$stage/Ui"
for file in "$repo"/*.qml "$repo"/*.js "$repo"/*.sh "$repo"/*.py; do ln -s "$file" "$stage/${file##*/}"; done
cp "$repo/tests/layout-ui-smoke.qml" "$stage/shell.qml"
cp "$repo/tests/layout-empty-config.json" "$stage/config.json"
status=0
LAYOUT_TEST_CONFIG="$stage/config.json" \
  QT_QPA_PLATFORM=wayland QT_QPA_PLATFORMTHEME=basic QT_QUICK_BACKEND=software \
  timeout 20s qs --no-color -p "$stage/shell.qml" > "$stage/result.log" 2>&1 || status=$?
tail -n 70 "$stage/result.log"
if [ "$status" != 0 ] || ! rg -q 'LAYOUT_UI_TOTAL 6 passed, 0 failed' "$stage/result.log" \
    || rg -q 'FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop' "$stage/result.log"; then exit 1; fi
