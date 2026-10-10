#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
shell_dir=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}
stage=$(mktemp -d /tmp/omaglimpse-sampling-tests.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/runtime"
chmod 700 "$stage/runtime"
ln -s "$shell_dir/Commons" "$stage/Commons"
ln -s "$shell_dir/Ui" "$stage/Ui"
for file in "$repo"/*.qml "$repo"/*.js; do ln -s "$file" "$stage/${file##*/}"; done
cp "$repo/tests/sampling-ui-smoke.qml" "$stage/shell.qml"
status=0
XDG_RUNTIME_DIR="$stage/runtime" QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=basic QT_QUICK_BACKEND=software \
  timeout 20s qs --no-color -p "$stage/shell.qml" > "$stage/result.log" 2>&1 || status=$?
cat "$stage/result.log"
if [ "$status" != 0 ] || ! rg -q 'SAMPLING_UI_TOTAL 8 passed, 0 failed' "$stage/result.log" \
    || rg -q 'FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop' "$stage/result.log"; then
  exit 1
fi
