import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WidgetModel.js" as Model
import "WidgetConfig.js" as Config
import "WidgetTheme.js" as Theme
import "SamplingModel.js" as Sampling
import "WidgetSizing.js" as Sizing

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
  property bool samplingEnabled: true
  property real samplingMultiplier: 1
  readonly property bool samplingActive: root.samplingEnabled && root.visible
  signal gpuSelected(string deviceId)

  // --- Config-driven settings ---
  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property int refreshInterval: Config.widgetRefreshInterval(root.config, root.widgetId)
  readonly property bool showCpu: root.widgetCfg.showCpu !== false
  readonly property bool showRam: root.widgetCfg.showRam !== false
  readonly property bool showGpu: root.widgetCfg.showGpu !== false
  readonly property real widgetGaugeDiameter: Number(root.widgetCfg.gaugeDiameter) || root.gaugeDiameter
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0
  readonly property real requestedHeight: Sizing.requestedHeight(root.widgetCfg.cardHeight)
  // Compact only when the preferred rings plus full labels cannot fit. A fixed
  // height breakpoint made a taller card suddenly halve its ring diameter.
  readonly property real fullLayoutHeight: root.baseGaugeDiameter + 40 + (root.showGpu ? 78 : 40)
  readonly property bool compactLayout: root.requestedHeight > 0 && root.requestedHeight < root.fullLayoutHeight
  readonly property int contentPadding: root.compactLayout ? 8 : 20
  readonly property int gaugeSpacing: root.compactLayout ? 8 : 16
  readonly property real minimumCardHeight: root.showGpu ? 110 : 80
  readonly property int visibleGaugeCount: (root.showCpu ? 1 : 0) + (root.showRam ? 1 : 0) + (root.showGpu ? 1 : 0)
  readonly property real baseGaugeDiameter: {
    if (widgetCardWidth <= 0) return widgetGaugeDiameter
    var avail = widgetCardWidth - 40 - (visibleGaugeCount - 1) * 16
    return Math.max(40, Math.min(widgetGaugeDiameter, avail / Math.max(1, visibleGaugeCount)))
  }
  readonly property real effectiveGaugeDiameter: root.requestedHeight > 0
    ? Math.max(40, Math.min(root.baseGaugeDiameter,
      root.requestedHeight - 2 * root.contentPadding - (root.showGpu ? (root.compactLayout ? 52 : 78) : 40)))
    : root.baseGaugeDiameter

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: root.contentPadding

  width: widgetCardWidth > 0 ? widgetCardWidth : Math.max(300,
    root.widgetGaugeDiameter * root.visibleGaugeCount + Math.max(0, root.visibleGaugeCount - 1) * 16 + 40)
  readonly property real naturalCardHeight: root.visibleGaugeCount === 0 ? 80 : Math.max(80, root.baseGaugeDiameter + (root.showGpu ? 78
    : 8 + gaugeFont.height + ((root.showCpu && root.cpuUser > 0) || (root.showRam && root.ramUsedGb > 0) ? 4 + gaugeFont.height : 0)) + 40)
  height: Sizing.cardHeight(root.widgetCfg.cardHeight, root.naturalCardHeight, root.minimumCardHeight)
  FontMetrics { id: gaugeFont; font.family: Style.font.family; font.pixelSize: 10 }


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
    if (!root.samplingActive) return
    if (root.showRam) memInfoFile.reload()
    if (root.showCpu) cpuStatFile.reload()
  }

  function updateMemInfo(raw) {
    if (!root.samplingActive) return
    var info = Model.parseMemInfo(raw)
    root.memReady = info.valid
    if (info.valid) root.memValue = info.percent
    ramUsedGb = info.usedGb
    ramFreeGb = info.freeGb
  }

  function updateCpuStat(raw) {
    if (!root.samplingActive) return
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
    path: root.samplingActive && root.showRam ? "/proc/meminfo" : ""
    watchChanges: false
    printErrors: false
    onLoaded: root.updateMemInfo(text())
  }

  // Read /proc/stat via FileView — no process spawn
  FileView {
    id: cpuStatFile
    path: root.samplingActive && root.showCpu ? "/proc/stat" : ""
    watchChanges: false
    printErrors: false
    onLoaded: root.updateCpuStat(text())
  }

  Timer {
    objectName: "systemSamplingTimer"
    interval: Sampling.interval(root.refreshInterval, root.samplingMultiplier)
    running: root.samplingActive && (root.showCpu || root.showRam)
    repeat: true
    onTriggered: root.refresh()
  }

  onShowCpuChanged: {
    root.prevCpuStat = null
    root.cpuReady = false
    if (root.showCpu) Qt.callLater(root.refresh)
  }
  onShowRamChanged: if (root.showRam) Qt.callLater(root.refresh)
  onSamplingActiveChanged: {
    root.prevCpuStat = null
    root.cpuReady = false
    root.cpuUser = root.cpuSystem = 0
    if (root.samplingActive) Qt.callLater(root.refresh)
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
    objectName: "widgetSizingContent"
    anchors.centerIn: parent
    spacing: root.gaugeSpacing

    CircularGauge {
      value: root.cpuValue
      displayText: root.cpuReady ? "" : "—"
      label: "CPU"
      subLabel: !root.compactLayout && root.cpuUser > 0 ? Math.round(root.cpuUser)
        + (root.effectiveGaugeDiameter < 64 ? "% usr" : "% user") : ""
      accentColor: Theme.resolveGaugeColor(root.config, root.widgetId, root.cpuValue, root.accentColor)
      textColor: root.textColor
      subTextColor: Theme.resolveMutedColor(root.textColor)
      diameter: root.effectiveGaugeDiameter
      labelSpacing: root.compactLayout ? 3 : 8
      Accessible.description: "CPU " + Math.round(root.cpuValue) + " percent, " + Math.round(root.cpuUser) + " percent user"
      visible: root.showCpu
    }

    CircularGauge {
      value: root.memValue
      displayText: root.memReady ? "" : "—"
      label: "RAM"
      subLabel: !root.compactLayout && root.ramUsedGb > 0
        ? (root.effectiveGaugeDiameter < 64 ? root.ramUsedGb.toFixed(1) + "/" + (root.ramUsedGb + root.ramFreeGb).toFixed(0) + "G"
          : root.ramUsedGb.toFixed(1) + " / " + (root.ramUsedGb + root.ramFreeGb).toFixed(1) + " GB") : ""
      accentColor: Theme.resolveGaugeColor(root.config, root.widgetId, root.memValue, root.accentColor)
      textColor: root.textColor
      subTextColor: Theme.resolveMutedColor(root.textColor)
      diameter: root.effectiveGaugeDiameter
      labelSpacing: root.compactLayout ? 3 : 8
      Accessible.description: "Memory " + root.ramUsedGb.toFixed(1) + " GB used"
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
      compact: root.compactLayout
      visible: root.showGpu
      onSelected: function(deviceId) { root.gpuSelected(deviceId) }
    }
  }
}
