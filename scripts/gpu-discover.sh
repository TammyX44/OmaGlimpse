#!/bin/sh
# Cached inventory only. Live sysfs readings are made by FileView; no packages,
# elevated permissions or GPU wake-up commands are needed for discovery.
intel_tool=0
command -v intel_gpu_top >/dev/null 2>&1 && intel_tool=1
for card in /sys/class/drm/card[0-9]*; do
  base=${card##*/}
  case ${base#card} in ''|*[!0-9]*) continue ;; esac
  device=$card/device
  [ -r "$device/uevent" ] || continue
  pci= driver= vendor= name= temp= busy= used= total= runtime=
  while IFS='=' read -r key value; do
    case $key in
      PCI_SLOT_NAME) pci=$value ;;
      DRIVER) driver=$value ;;
      PCI_ID) case $value in 8086:*) vendor=intel ;; 1002:*) vendor=amd ;; 10DE:*) vendor=nvidia ;; *) vendor=unknown ;; esac ;;
    esac
  done < "$device/uevent"
  [ -n "$pci" ] || continue
  if command -v lspci >/dev/null 2>&1; then
    name=$(LC_ALL=C timeout 2s lspci -D -mm -s "$pci" 2>/dev/null | cut -d '"' -f 6)
  fi
  for f in "$device"/hwmon/hwmon*/temp1_input; do
    if [ -r "$f" ]; then temp=$f; break; fi
  done
  [ -r "$device/gpu_busy_percent" ] && busy=$device/gpu_busy_percent
  [ -r "$device/mem_info_vram_used" ] && used=$device/mem_info_vram_used
  [ -r "$device/mem_info_vram_total" ] && total=$device/mem_info_vram_total
  [ -r "$device/power/runtime_status" ] && runtime=$device/power/runtime_status
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pci" "$name" "$vendor" "$driver" "$card" "$temp" "$busy" "$used" "$total" "$runtime" "$intel_tool"
done
