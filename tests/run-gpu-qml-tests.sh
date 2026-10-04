#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
shell_dir=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}
stage=$(mktemp -d /tmp/omaglimpse-qml-tests.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/runtime"
mkdir -p "$stage/bin" "$stage/fixtures"
chmod 700 "$stage/runtime"
ln -s "$shell_dir/Commons" "$stage/Commons"
ln -s "$shell_dir/Ui" "$stage/Ui"
for file in "$repo"/*.qml "$repo"/*.js "$repo"/*.sh; do ln -s "$file" "$stage/${file##*/}"; done
cp "$repo/tests/gpu-ui-smoke.qml" "$stage/shell.qml"
printf 'active\n' > "$stage/fixtures/power"
printf '40500\n' > "$stage/fixtures/temp"
printf '27\n' > "$stage/fixtures/busy"
printf '2097152\n' > "$stage/fixtures/used"
printf '2147483648\n' > "$stage/fixtures/total"
cat > "$stage/gpu-test-discover.sh" <<'EOF'
#!/bin/sh
f=$GPU_FIXTURE_DIR
printf '0000:00:02.0\tIntel UHD Graphics\tintel\ti915\t/sys/class/drm/card2\t\t\t\t\t%s/power\t1\n' "$f"
printf '0000:01:00.0\tGeForce RTX 3050\tnvidia\tnvidia\t/sys/class/drm/card1\t\t\t\t\t%s/power\t0\n' "$f"
printf '0000:02:00.0\tRadeon RX 6800\tamd\tamdgpu\t/sys/class/drm/card3\t%s/temp\t%s/busy\t%s/used\t%s/total\t%s/power\t0\n' "$f" "$f" "$f" "$f" "$f"
EOF
cat > "$stage/bin/nvidia-smi" <<'EOF'
#!/bin/sh
printf '00000000:01:00.0, GeForce RTX 3050, 32, 123, 6144, 53\n'
EOF
cat > "$stage/bin/intel_gpu_top" <<'EOF'
#!/bin/sh
printf '[\n{"engines":{"Render/3D/0":{"busy":11}}}\n'
while :; do sleep 1; printf ',\n{"engines":{"Render/3D/0":{"busy":11}}}\n'; done
EOF
chmod +x "$stage/bin/nvidia-smi" "$stage/bin/intel_gpu_top"
status=0
GPU_FIXTURE_DIR="$stage/fixtures" PATH="$stage/bin:$PATH" \
  XDG_RUNTIME_DIR="$stage/runtime" QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=basic QT_QUICK_BACKEND=software \
  timeout 30s qs --no-color -p "$stage/shell.qml" > "$stage/result.log" 2>&1 || status=$?
cat "$stage/result.log"
if [ "$status" != 0 ] || ! rg -q 'GPU_UI_TOTAL 9 passed, 0 failed' "$stage/result.log" \
    || rg -q 'FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop' "$stage/result.log"; then
  exit 1
fi
