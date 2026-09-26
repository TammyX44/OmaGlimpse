import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WidgetModel.js" as Model
import "WidgetConfig.js" as Config
import "WidgetTheme.js" as Theme

// System monitor card: CPU, RAM, and GPU circular gauges.
// Colors, refresh interval, and sub-widget visibility are config-driven.
BorderSurface {
  id: root

  // --- Properties set by Widgets.qml ---
  property string widgetId: "systemMonitor"
  property var config: ({})
  property color cardColor: Qt.rgba(0.09, 0.09, 0.10, 0.95)
  property color borderColor: Qt.rgba(1, 1, 1, 0.12)
  property color textColor: Color.foreground
  property color accentColor: Color.accent
  property real cardRadius: 18
  property real gaugeDiameter: 120

  // --- Config-driven settings ---
  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property int refreshInterval: Config.widgetRefreshInterval(root.config, root.widgetId)
  readonly property bool showCpu: root.widgetCfg.showCpu !== false
  readonly property bool showRam: root.widgetCfg.showRam !== false
  readonly property bool showGpu: root.widgetCfg.showGpu !== false
  readonly property real widgetGaugeDiameter: Number(root.widgetCfg.gaugeDiameter) || root.gaugeDiameter
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0
  // When cardWidth is set, scale gauges down to fit so the slider always works
  readonly property int visibleGaugeCount: (root.showCpu ? 1 : 0) + (root.showRam ? 1 : 0) + (root.showGpu && root.gpuAvailable ? 1 : 0)
  readonly property real effectiveGaugeDiameter: {
    if (widgetCardWidth <= 0) return widgetGaugeDiameter
    var avail = widgetCardWidth - 40 - (visibleGaugeCount - 1) * 16
    return Math.max(40, Math.min(widgetGaugeDiameter, avail / Math.max(1, visibleGaugeCount)))
  }

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: 20

  width: widgetCardWidth > 0 ? widgetCardWidth : Math.max(300, gaugeRow.implicitWidth + 40)
  height: gaugeRow.implicitHeight + 40


  // --- CPU data ---
  property var prevCpuStat: null
  property real cpuValue: 0
  property real memValue: 0
  property bool cpuReady: false
  property bool memReady: false
  property real cpuUser: 0
  property real cpuSystem: 0
  property real ramUsedGb: 0
  property real ramFreeGb: 0

  // --- GPU data ---
  property real gpuValue: 0
  property real gpuMemUsed: 0
  property real gpuMemTotal: 0
  property real gpuTemp: 0
  property bool gpuAvailable: false
  property bool gpuChecked: false  // set true after first nvidia-smi attempt

  function refresh() {
    memInfoFile.reload()
    cpuStatFile.reload()
    // Only spawn nvidia-smi if GPU is shown AND we know a GPU exists
    // (or we haven't checked yet). This avoids 61 failed spawns/min
    // on systems without an NVIDIA GPU.
    if (root.showGpu && !root.gpuChecked && !gpuProc.running) {
      gpuProc.running = true
    } else if (root.showGpu && root.gpuAvailable && !gpuProc.running) {
      gpuProc.running = true
    }
  }

  function updateMemInfo(raw) {
    var info = Model.parseMemInfo(raw)
    root.memReady = info.valid
    if (info.valid) root.memValue = info.percent
    ramUsedGb = info.usedGb
    ramFreeGb = info.freeGb
  }

  function updateCpuStat(raw) {
    var next = Model.parseCpuStat(raw)
    if (next) {
      var percent = Model.cpuSnapshotPercent(prevCpuStat, next)
      root.cpuReady = percent !== null
      if (root.cpuReady) root.cpuValue = percent
      var bd = Model.cpuBreakdown(prevCpuStat, next)
      cpuUser = bd.user
      cpuSystem = bd.system
      prevCpuStat = next
    } else {
      root.cpuReady = false
      root.prevCpuStat = null
      root.cpuUser = root.cpuSystem = 0
    }
  }

  function updateGpu(raw) {
    root.gpuChecked = true
    var parsed = Model.parseGpuLine(raw)
    if (!parsed) { gpuAvailable = false; return }
    gpuAvailable = true
    gpuValue = parsed.utilization
    gpuMemUsed = parsed.memUsed === null ? 0 : parsed.memUsed
    gpuMemTotal = parsed.memTotal === null ? 0 : parsed.memTotal
    gpuTemp = parsed.temp === null ? 0 : parsed.temp
  }

  // Read /proc/meminfo via FileView — no process spawn
  FileView {
    id: memInfoFile
    path: "/proc/meminfo"
    watchChanges: false
    printErrors: false
    onLoaded: root.updateMemInfo(text())
  }

  // Read /proc/stat via FileView — no process spawn
  FileView {
    id: cpuStatFile
    path: "/proc/stat"
    watchChanges: false
    printErrors: false
    onLoaded: root.updateCpuStat(text())
  }

  // GPU stats: tries nvidia-smi, then AMD rocm-smi, then the amdgpu
  // gpu_busy_percent sysfs counter. If no source is usable, the gauge hides.
  Process {
    id: gpuProc
    command: ["sh", "-c",
      "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || " +
      "(rocm_output=''; " +
      "if command -v rocm-smi >/dev/null 2>&1; then " +
      "rocm_output=$(rocm-smi --showuse --showmeminfo vram --showtemp hotspot 2>/dev/null); " +
      "if [ -n \"$rocm_output\" ]; then " +
      "printf '%s\\n' \"$rocm_output\" | awk 'NR<=2{print}' | tr '\\n' ',' | sed 's/.*: //g' | tr -d ' '; " +
      "exit 0; fi; fi; " +
      "for f in /sys/class/drm/card*/device/gpu_busy_percent; do " +
      "if [ -f \"$f\" ]; then v=$(cat \"$f\" 2>/dev/null); " +
      "case \"$v\" in ''|*[!0-9]*) continue;; esac; " +
      "printf '%s,0,0,0\\n' \"$v\"; exit 0; fi; " +
      "done; exit 1) 2>/dev/null || echo ''"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateGpu(text) }
  }

  Timer {
    interval: root.refreshInterval
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // A discrete GPU can be unavailable while runtime-suspended. Re-probe at a
  // low rate so it can appear after waking without spawning a process every
  // normal refresh on machines that have no supported GPU source.
  Timer {
    interval: 30000
    running: root.showGpu && root.gpuChecked && !root.gpuAvailable
    repeat: true
    onTriggered: {
      if (!gpuProc.running) gpuProc.running = true
    }
  }

  Component.onCompleted: root.refresh()
  Text {
    anchors.centerIn: parent
    visible: root.visibleGaugeCount === 0
    textFormat: Text.PlainText
    text: "No system metrics enabled"
    color: Theme.resolveMutedColor(root.textColor)
    font.family: Style.font.family
    font.pixelSize: 12
    horizontalAlignment: Text.AlignHCenter
    width: Math.max(0, parent.width - 40)
  }


  Row {
    id: gaugeRow
    anchors.centerIn: parent
    spacing: 16

    CircularGauge {
      value: root.cpuValue
      displayText: root.cpuReady ? "" : "—"
      label: "CPU"
      subLabel: root.cpuUser > 0 ? Math.round(root.cpuUser)
        + (root.effectiveGaugeDiameter < 64 ? "% usr" : "% user") : ""
      accentColor: Theme.resolveGaugeColor(root.config, root.widgetId, root.cpuValue, root.accentColor)
      textColor: root.textColor
      subTextColor: Theme.resolveMutedColor(root.textColor)
      diameter: root.effectiveGaugeDiameter
      visible: root.showCpu
    }

    CircularGauge {
      value: root.memValue
      displayText: root.memReady ? "" : "—"
      label: "RAM"
      subLabel: root.ramUsedGb > 0
        ? (root.effectiveGaugeDiameter < 64 ? root.ramUsedGb.toFixed(1) + "/" + (root.ramUsedGb + root.ramFreeGb).toFixed(0) + "G"
          : root.ramUsedGb.toFixed(1) + " / " + (root.ramUsedGb + root.ramFreeGb).toFixed(1) + " GB") : ""
      accentColor: Theme.resolveGaugeColor(root.config, root.widgetId, root.memValue, root.accentColor)
      textColor: root.textColor
      subTextColor: Theme.resolveMutedColor(root.textColor)
      diameter: root.effectiveGaugeDiameter
      visible: root.showRam
    }

    CircularGauge {
      value: root.gpuValue
      label: "GPU"
      subLabel: root.gpuAvailable
        ? (root.gpuTemp > 0 ? root.gpuTemp + "°C" : "")
        : ""
      accentColor: Theme.resolveGaugeColor(root.config, root.widgetId, root.gpuValue, root.accentColor)
      textColor: root.textColor
      subTextColor: Theme.resolveMutedColor(root.textColor)
      diameter: root.effectiveGaugeDiameter
      visible: root.showGpu && root.gpuAvailable
    }
  }
}
