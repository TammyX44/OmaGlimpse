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
  property var gpuMonitor: null
  property bool editMode: false
  signal gpuSelected(string deviceId)

  // --- Config-driven settings ---
  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property int refreshInterval: Config.widgetRefreshInterval(root.config, root.widgetId)
  readonly property bool showCpu: root.widgetCfg.showCpu !== false
  readonly property bool showRam: root.widgetCfg.showRam !== false
  readonly property bool showGpu: root.widgetCfg.showGpu !== false
  readonly property real widgetGaugeDiameter: Number(root.widgetCfg.gaugeDiameter) || root.gaugeDiameter
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0
  // When cardWidth is set, scale gauges down to fit so the slider always works
  readonly property int visibleGaugeCount: (root.showCpu ? 1 : 0) + (root.showRam ? 1 : 0) + (root.showGpu ? 1 : 0)
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

  function refresh() {
    if (root.showRam) memInfoFile.reload()
    if (root.showCpu) cpuStatFile.reload()
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

  Timer {
    interval: root.refreshInterval
    running: root.showCpu || root.showRam
    repeat: true
    onTriggered: root.refresh()
  }

  onShowCpuChanged: {
    root.prevCpuStat = null
    root.cpuReady = false
    if (root.showCpu) Qt.callLater(root.refresh)
  }
  onShowRamChanged: if (root.showRam) Qt.callLater(root.refresh)

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

    GpuGauge {
      devices: root.gpuMonitor ? root.gpuMonitor.devices : []
      selectedId: root.widgetCfg.gpuDevice || ""
      aliases: root.widgetCfg.gpuAliases || ({})
      discoveryReady: root.gpuMonitor ? root.gpuMonitor.discoveryReady : false
      interactive: !root.editMode && !Config.widgetClickThrough(root.config, root.widgetId)
      accentColor: Theme.resolveGaugeColor(root.config, root.widgetId,
        device && device.utilization !== null ? device.utilization : 0, root.accentColor)
      textColor: root.textColor
      subTextColor: Theme.resolveMutedColor(root.textColor)
      diameter: root.effectiveGaugeDiameter
      visible: root.showGpu
      onSelected: function(deviceId) { root.gpuSelected(deviceId) }
    }
  }
}
