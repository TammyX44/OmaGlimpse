#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
shell_dir=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}
stage=$(mktemp -d /tmp/omaglimpse-safe-field-tests.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/runtime" "$stage/bin"
chmod 700 "$stage/runtime"
ln -s "$shell_dir/Commons" "$stage/Commons"
ln -s "$shell_dir/Ui" "$stage/Ui"
for file in "$repo"/*.qml "$repo"/*.js "$repo"/*.py; do cp "$file" "$stage/${file##*/}"; done
cp "$repo/tests/safe-textfield-ui.qml" "$stage/shell.qml"
# Use a delayed stub, never the user's clipboard. It also exercises cancellation.
cp "$repo/tests/safe-paste-fixture.py" "$stage/bin/wl-paste"
chmod +x "$stage/bin/wl-paste"
status=0
PATH="$stage/bin:$PATH" XDG_RUNTIME_DIR="$stage/runtime" \
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=basic QT_QUICK_BACKEND=software \
  timeout --kill-after=2s 15s qs --no-color -p "$stage/shell.qml" > "$stage/result.log" 2>&1 || status=$?
cat "$stage/result.log"
if [ "$status" != 0 ] || ! rg -q 'SAFE_FIELD_TOTAL 6 passed, 0 failed' "$stage/result.log" \
    || rg -q 'FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop' "$stage/result.log"; then exit 1; fi
