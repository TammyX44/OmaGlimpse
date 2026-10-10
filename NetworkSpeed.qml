import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WidgetModel.js" as Model
import "WidgetConfig.js" as Config
import "WidgetSizing.js" as Sizing
import "NetworkHistory.js" as History

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
  property bool samplingEnabled: true
  property real samplingMultiplier: 1

  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property int refreshInterval: Config.widgetRefreshInterval(root.config, root.widgetId)
  readonly property int samplingInterval: Math.min(2147483647, Math.max(1,
    refreshInterval * (isFinite(samplingMultiplier) ? Math.max(1, samplingMultiplier) : 1)))
  readonly property bool showHistory: widgetCfg.showHistory !== false
  readonly property bool fixedScale: widgetCfg.scaleMode === "fixed"
  readonly property real scaleBytes: fixedScale ? History.fixedScale(widgetCfg.scaleLimitMbps) : autoScale
  readonly property string scaleLabel: Model.formatSpeed(scaleBytes) + (fixedScale ? " ref" : " auto")
  readonly property string interfaceFilter: String(root.widgetCfg.interface || "auto")
  readonly property real widgetGaugeDiameter: Number(root.widgetCfg.gaugeDiameter) || root.gaugeDiameter
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0
  readonly property real requestedHeight: Sizing.requestedHeight(root.widgetCfg.cardHeight)
  readonly property bool compactNumbers: root.requestedHeight > 0 && root.requestedHeight < 160
  readonly property bool compactSizing: root.requestedHeight > 0 && root.requestedHeight < 260
  readonly property int contentPadding: root.compactSizing ? 8 : 20
  readonly property real minimumCardHeight: root.showHistory ? 90 : 80
  readonly property real baseGaugeDiameter: {
    if (widgetCardWidth <= 0) return widgetGaugeDiameter
    var avail = widgetCardWidth - 40 - 8
    return Math.max(40, Math.min(widgetGaugeDiameter, avail / 2))
  }
  readonly property real effectiveGaugeDiameter: root.requestedHeight > 0
    ? Math.max(40, Math.min(root.baseGaugeDiameter, root.requestedHeight
      - 2 * root.contentPadding - interfaceHeader.implicitHeight - (root.showHistory ? historyGraph.height : 0)
      - (root.showHistory ? 3 : 2) * content.spacing - networkFont.height - (root.compactSizing ? 3 : 8)
      - (root.compactSizing ? 0 : 4 + networkFont.height))) : root.baseGaugeDiameter

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: root.contentPadding

  width: widgetCardWidth > 0 ? widgetCardWidth : Math.max(300, root.widgetGaugeDiameter * 2 + 48)
  readonly property real naturalCardHeight: content.implicitHeight + 40
  height: Sizing.cardHeight(root.widgetCfg.cardHeight, root.naturalCardHeight, root.minimumCardHeight)
  FontMetrics { id: networkFont; font.family: Style.font.family; font.pixelSize: 10 }


  property var prevDevs: null
  property real prevTime: 0
  property real rxSpeed: 0
  property real txSpeed: 0
  property string defaultInterface: ""
  property string activeInterface: ""
  property bool sampleReady: false
  property string sampleState: "Measuring…"
  property real autoScale: History.minimumScale
  property var history: []
  property real historyTime: 0

  function refresh() {
    if (!root.samplingEnabled) return
    routeFile.reload()
    netFile.reload()
  }

  function updateNet(raw, timestamp) {
    if (!root.samplingEnabled) return
    var now = timestamp === undefined ? Date.now() : timestamp
    root.historyTime = now
    var devs = Model.parseNetDev(raw)
    var iface = root.interfaceFilter === "auto"
      ? (root.defaultInterface && devs[root.defaultInterface]
        ? root.defaultInterface
        : Model.pickPrimaryInterface(devs, root.prevDevs))
      : root.interfaceFilter

    if (!iface || !devs[iface]) {
      root.resetBaseline()
      root.sampleState = "Unavailable"
      return
    }

    if (root.activeInterface !== iface || !root.prevDevs || !root.prevDevs[iface]) {
      root.resetBaseline()
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
    if (elapsedMs <= 0 || elapsedMs > root.samplingInterval * 2.5 ||
        devs[iface].rxBytes < root.prevDevs[iface].rxBytes ||
        devs[iface].txBytes < root.prevDevs[iface].txBytes) {
      root.rxSpeed = 0
      root.txSpeed = 0
      root.sampleReady = false
      root.sampleState = "Measuring…"
      root.history = History.append(root.history, now, 0, 0, true)
      root.prevDevs = devs
      root.prevTime = now
      return
    }
    if (root.prevTime > 0 && elapsedMs > 0) {
      var speed = Model.netSpeed(root.prevDevs[iface], devs[iface], elapsedMs)
      root.rxSpeed = speed.rx
      root.txSpeed = speed.tx
      root.sampleReady = true
      root.autoScale = History.nextScale(root.autoScale, speed.rx, speed.tx, elapsedMs)
      root.history = History.append(root.history, now, speed.rx, speed.tx, false)
    }
    root.prevDevs = devs
    root.prevTime = now
  }

  function resetBaseline() {
    root.history = []
    root.autoScale = History.minimumScale
    root.prevDevs = null
    root.prevTime = 0
    root.activeInterface = ""
    root.rxSpeed = 0
    root.txSpeed = 0
    root.sampleReady = false
    root.sampleState = root.samplingEnabled ? "Measuring…" : "Paused"
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
      if (!root.samplingEnabled) return
      root.resetBaseline()
      root.sampleState = "Unavailable"
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
    objectName: "networkSampleTimer"
    interval: root.samplingInterval
    running: root.samplingEnabled
    repeat: true
    onTriggered: root.refresh()
  }

  onInterfaceFilterChanged: Qt.callLater(function() {
    root.resetBaseline()
    root.refresh()
  })
  onSamplingEnabledChanged: {
    root.resetBaseline()
    if (root.samplingEnabled) root.refresh()
  }
  onSamplingIntervalChanged: {
    root.resetBaseline()
    if (root.samplingEnabled) root.refresh()
  }
  Component.onCompleted: root.refresh()

  Column {
    id: content
    objectName: "widgetSizingContent"
    anchors.centerIn: parent
    spacing: root.compactSizing ? 4 : 8
    width: root.width - 2 * root.contentPadding

    // Interface name as a header
    Text {
      id: interfaceHeader
      objectName: "networkInterfaceHeader"
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: (root.activeInterface || (root.interfaceFilter !== "auto" ? root.interfaceFilter : "—"))
        + (root.compactSizing && !root.sampleReady ? " · " + root.sampleState : "")
      Accessible.name: text
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
      font.family: Style.font.family
      font.pixelSize: 11
      font.bold: true
      font.letterSpacing: 1
      anchors.horizontalCenter: parent.horizontalCenter
    }

    Row {
      id: gaugeRow
      visible: !root.compactNumbers
      spacing: 8
      anchors.horizontalCenter: parent.horizontalCenter

      CircularGauge {
        objectName: "networkDownloadGauge"
        value: Math.min(100, root.rxSpeed / root.scaleBytes * 100)
        animateValue: false
        label: "DOWN"
        displayText: root.sampleReady ? Model.formatSpeed(root.rxSpeed) : "—"
        subLabel: root.compactSizing ? "" : root.sampleReady ? root.scaleLabel : root.sampleState
        labelSpacing: root.compactSizing ? 3 : 8
        accentColor: root.accentColor
        textColor: root.textColor
        diameter: root.effectiveGaugeDiameter
      }

      CircularGauge {
        value: Math.min(100, root.txSpeed / root.scaleBytes * 100)
        animateValue: false
        label: "UP"
        displayText: root.sampleReady ? Model.formatSpeed(root.txSpeed) : "—"
        subLabel: root.compactSizing ? "" : root.sampleReady ? root.scaleLabel : root.sampleState
        labelSpacing: root.compactSizing ? 3 : 8
        accentColor: root.accentColor
        textColor: root.textColor
        diameter: root.effectiveGaugeDiameter
      }
    }

    Row {
      visible: root.compactNumbers
      width: parent.width
      spacing: 8
      Repeater {
        model: [{label:"DOWN",speed:root.rxSpeed},{label:"UP",speed:root.txSpeed}]
        Column {
          required property var modelData
          width: (content.width - 8) / 2
          spacing: 2
          Text {
            width: parent.width
            text: parent.modelData.label
            textFormat: Text.PlainText
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: 10
            horizontalAlignment: Text.AlignHCenter
          }
          Text {
            width: parent.width
            text: root.sampleReady ? Model.formatSpeed(parent.modelData.speed) : "—"
            textFormat: Text.PlainText
            color: root.accentColor
            font.family: Style.font.family
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            Accessible.name: parent.modelData.label + " " + text
            Accessible.description: root.sampleReady ? root.scaleLabel : root.sampleState
          }
        }
      }
    }

    Canvas {
      id: historyGraph
      objectName: "networkHistoryGraph"
      visible: root.showHistory
      width: parent.width
      height: root.compactNumbers ? 16 : root.compactSizing ? 24 : 36
      readonly property var points: root.history
      readonly property real sampleTime: root.historyTime
      readonly property real referenceScale: root.scaleBytes
      readonly property color downColor: root.accentColor
      readonly property color upColor: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.65)
      onPointsChanged: requestPaint()
      onSampleTimeChanged: requestPaint()
      onReferenceScaleChanged: requestPaint()
      onDownColorChanged: requestPaint()
      onUpColorChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onVisibleChanged: if (visible) requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        ctx.strokeStyle = Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.10)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(0, height - 1)
        ctx.lineTo(width, height - 1)
        ctx.stroke()
        var channels = ["rx", "tx"]
        for (var c = 0; c < channels.length; c++) {
          ctx.strokeStyle = c === 0 ? downColor : upColor
          ctx.lineWidth = 1.5
          var lines = History.segments(points, channels[c], sampleTime, width,
            height - 3, referenceScale, root.samplingInterval * 2.5)
          for (var i = 0; i < lines.length; i++) {
            ctx.beginPath()
            for (var j = 0; j < lines[i].length; j++) {
              var p = lines[i][j]
              if (j === 0) ctx.moveTo(p.x, p.y + 1)
              else ctx.lineTo(p.x, p.y + 1)
            }
            ctx.stroke()
          }
        }
      }
    }
  }
}
