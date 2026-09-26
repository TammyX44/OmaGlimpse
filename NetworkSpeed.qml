import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WidgetModel.js" as Model
import "WidgetConfig.js" as Config

// Network speed card: download and upload speed gauges.
// Reads /proc/net/dev and computes delta between polls.
BorderSurface {
  id: root

  property string widgetId: "networkSpeed"
  property var config: ({})
  property color cardColor: Qt.rgba(0.09, 0.09, 0.10, 0.95)
  property color borderColor: Qt.rgba(1, 1, 1, 0.12)
  property color textColor: Color.foreground
  property color accentColor: Color.accent
  property real cardRadius: 18
  property real gaugeDiameter: 120

  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property int refreshInterval: Config.widgetRefreshInterval(root.config, root.widgetId)
  readonly property string interfaceFilter: String(root.widgetCfg.interface || "auto")
  readonly property real widgetGaugeDiameter: Number(root.widgetCfg.gaugeDiameter) || root.gaugeDiameter
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0
  readonly property real effectiveGaugeDiameter: {
    if (widgetCardWidth <= 0) return widgetGaugeDiameter
    var avail = widgetCardWidth - 40 - 8
    return Math.max(40, Math.min(widgetGaugeDiameter, avail / 2))
  }

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: 20

  width: widgetCardWidth > 0 ? widgetCardWidth : Math.max(300, gaugeRow.implicitWidth + 40)
  height: gaugeRow.implicitHeight + 60


  property var prevDevs: null
  property real prevTime: 0
  property real rxSpeed: 0
  property real txSpeed: 0
  property string defaultInterface: ""
  property string activeInterface: ""
  property bool sampleReady: false
  property string sampleState: "Measuring…"

  function refresh() {
    routeFile.reload()
    netFile.reload()
  }

  function updateNet(raw) {
    var now = Date.now()
    var devs = Model.parseNetDev(raw)
    var iface = root.interfaceFilter === "auto"
      ? (root.defaultInterface && devs[root.defaultInterface]
        ? root.defaultInterface
        : Model.pickPrimaryInterface(devs, root.prevDevs))
      : root.interfaceFilter

    if (!iface || !devs[iface]) {
      root.activeInterface = ""
      root.rxSpeed = 0
      root.txSpeed = 0
      root.sampleReady = false
      root.sampleState = "Unavailable"
      root.prevDevs = devs
      root.prevTime = now
      return
    }

    if (root.activeInterface !== iface || !root.prevDevs || !root.prevDevs[iface]) {
      root.activeInterface = iface
      root.rxSpeed = 0
      root.txSpeed = 0
      root.sampleReady = false
      root.sampleState = "Measuring…"
      root.prevDevs = devs
      root.prevTime = now
      return
    }
    root.activeInterface = iface

    var elapsedMs = now - root.prevTime
    if (root.prevTime > 0 && elapsedMs > 0) {
      var speed = Model.netSpeed(root.prevDevs[iface], devs[iface], elapsedMs)
      root.rxSpeed = speed.rx
      root.txSpeed = speed.tx
      root.sampleReady = true
      root.sampleState = "5 MB/s ref"
    }
    root.prevDevs = devs
    root.prevTime = now
  }

  function resetBaseline() {
    root.prevDevs = null
    root.prevTime = 0
    root.activeInterface = ""
    root.rxSpeed = 0
    root.txSpeed = 0
    root.sampleReady = false
    root.sampleState = "Measuring…"
  }

  // Read /proc/net/dev via FileView — no process spawn, near-zero overhead.
  // /proc files don't support inotify for content changes, so we use
  // watchChanges: false and reload on a timer.
  FileView {
    id: netFile
    path: "/proc/net/dev"
    watchChanges: false
    printErrors: false
    onLoaded: root.updateNet(text())
    onLoadFailed: {
      root.activeInterface = ""
      root.rxSpeed = 0
      root.txSpeed = 0
      root.sampleReady = false
      root.sampleState = "Unavailable"
      root.prevDevs = null
    }
  }

  // The default route is a better primary-interface signal than cumulative
  // byte counts, which can be dominated by stale VPN/container devices.
  FileView {
    id: routeFile
    path: "/proc/net/route"
    watchChanges: false
    printErrors: false
    onLoaded: root.defaultInterface = Model.parseDefaultInterface(text())
  }

  Timer {
    interval: root.refreshInterval
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  onInterfaceFilterChanged: Qt.callLater(function() {
    root.resetBaseline()
    root.refresh()
  })
  Component.onCompleted: root.refresh()

  Column {
    id: content
    anchors.centerIn: parent
    spacing: 8

    // Interface name as a header
    Text {
      textFormat: Text.PlainText
      text: root.activeInterface || (root.interfaceFilter !== "auto" ? root.interfaceFilter : "—")
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
      font.family: Style.font.family
      font.pixelSize: 11
      font.bold: true
      font.letterSpacing: 1
      anchors.horizontalCenter: parent.horizontalCenter
    }

    Row {
      id: gaugeRow
      spacing: 8
      anchors.horizontalCenter: parent.horizontalCenter

      CircularGauge {
        value: Math.min(100, root.rxSpeed / (1024 * 1024) * 20) // scale: 5MB/s = 100%
        label: "DOWN"
        displayText: root.sampleReady ? Model.formatSpeed(root.rxSpeed) : "—"
        subLabel: root.sampleState
        accentColor: root.accentColor
        textColor: root.textColor
        diameter: root.effectiveGaugeDiameter
      }

      CircularGauge {
        value: Math.min(100, root.txSpeed / (1024 * 1024) * 20)
        label: "UP"
        displayText: root.sampleReady ? Model.formatSpeed(root.txSpeed) : "—"
        subLabel: root.sampleState
        accentColor: root.accentColor
        textColor: root.textColor
        diameter: root.effectiveGaugeDiameter
      }
    }
  }
}
