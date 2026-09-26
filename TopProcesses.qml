import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WidgetModel.js" as Model
import "WidgetConfig.js" as Config

// Top processes card: lists the top CPU-consuming processes.
// Config-driven colors, refresh interval, process count, and sort order.
BorderSurface {
  id: root

  // --- Properties set by Widgets.qml ---
  property string widgetId: "topProcesses"
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
  readonly property int processCount: Math.max(1, Math.min(15,
    Math.floor(Number(root.widgetCfg.processCount) || 5)))
  readonly property string sortBy: root.widgetCfg.sortBy === "mem" ? "mem" : "cpu"
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: 20

  width: widgetCardWidth > 0 ? widgetCardWidth : 300
  height: content.implicitHeight + 40


  property var processes: []
  property bool hasLoaded: false
  property string errorMessage: ""
  property string pendingStdout: ""
  property string pendingStderr: ""
  property int pendingExitCode: -1
  property bool stdoutReady: false
  property bool stderrReady: false
  property bool exitReady: false
  property bool refreshQueued: false

  function refresh() {
    if (proc.running) {
      root.refreshQueued = true
      return
    }
    root.pendingStdout = ""
    root.pendingStderr = ""
    root.pendingExitCode = -1
    root.stdoutReady = false
    root.stderrReady = false
    root.exitReady = false
    proc.running = true
  }

  function finishRefresh() {
    if (!root.stdoutReady || !root.stderrReady || !root.exitReady) return
    root.exitReady = false
    root.hasLoaded = true
    if (root.pendingExitCode === 0) {
      root.updateProcesses(root.pendingStdout)
      root.errorMessage = ""
    } else {
      root.errorMessage = root.pendingStderr.trim() || "Unable to read process data"
    }
    if (root.refreshQueued) {
      root.refreshQueued = false
      Qt.callLater(root.refresh)
    }
  }

  function updateProcesses(raw) {
    processes = Model.parseTopProcesses(raw, root.processCount)
  }

  Process {
    id: proc
    command: ["env", "LC_ALL=C", "ps", "-eo", "pid,comm,%cpu,%mem", "--sort=-" + (root.sortBy === "mem" ? "%mem" : "%cpu"), "--no-headers"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pendingStdout = String(text || "")
        root.stdoutReady = true
        root.finishRefresh()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pendingStderr = String(text || "")
        root.stderrReady = true
        root.finishRefresh()
      }
    }
    onExited: function(exitCode) {
      root.pendingExitCode = exitCode
      root.exitReady = true
      root.finishRefresh()
    }
  }

  Timer {
    interval: root.refreshInterval
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
  onProcessCountChanged: Qt.callLater(function() { root.refresh() })
  onSortByChanged: Qt.callLater(function() { root.refresh() })

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: 20
    anchors.rightMargin: 20
    anchors.topMargin: 20
    spacing: 10

    Text {
      textFormat: Text.PlainText
      text: "TOP PROCESSES"
      color: root.textColor
      font.family: Style.font.family
      font.pixelSize: 12
      font.bold: true
      font.letterSpacing: 1.5
    }

    Row {
      width: parent.width
      spacing: 0

      Text {
        textFormat: Text.PlainText
        text: "PROCESS"
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.4)
        font.family: Style.font.family
        font.pixelSize: 9
        font.bold: true
        font.letterSpacing: 1
        width: parent.width * 0.5
      }
      Text {
        textFormat: Text.PlainText
        text: root.sortBy === "mem" ? "MEM" : "CPU"
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.4)
        font.family: Style.font.family
        font.pixelSize: 9
        font.bold: true
        font.letterSpacing: 1
        width: parent.width * 0.25
        horizontalAlignment: Text.AlignRight
      }
      Text {
        textFormat: Text.PlainText
        text: root.sortBy === "mem" ? "CPU" : "MEM"
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.4)
        font.family: Style.font.family
        font.pixelSize: 9
        font.bold: true
        font.letterSpacing: 1
        width: parent.width * 0.25
        horizontalAlignment: Text.AlignRight
      }
    }

    Text {
      width: parent.width
      visible: !root.hasLoaded && root.processes.length === 0
      textFormat: Text.PlainText
      text: "Loading process data..."
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
      font.family: Style.font.family
      font.pixelSize: 11
    }

    Text {
      width: parent.width
      visible: root.errorMessage !== ""
      textFormat: Text.PlainText
      text: root.errorMessage
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: 11
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      visible: root.hasLoaded && root.errorMessage === "" && root.processes.length === 0
      textFormat: Text.PlainText
      text: "No processes found"
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
      font.family: Style.font.family
      font.pixelSize: 11
    }

    Repeater {
      model: root.processes

      Row {
        id: procRow
        required property var modelData
        required property int index

        width: content.width
        spacing: 0
        height: 22

        Text {
          textFormat: Text.PlainText
          text: procRow.modelData.name
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: 11
          elide: Text.ElideRight
          width: parent.width * 0.5
          anchors.verticalCenter: parent.verticalCenter
        }

        Item {
          width: parent.width * 0.25
          height: parent.height
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.fill: parent
            textFormat: Text.PlainText
            text: (root.sortBy === "mem"
              ? procRow.modelData.mem.toFixed(1)
              : procRow.modelData.cpu.toFixed(1)) + "%"
            color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.7)
            font.family: Style.font.family
            font.pixelSize: 11
            horizontalAlignment: Text.AlignRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          textFormat: Text.PlainText
          text: (root.sortBy === "mem"
            ? procRow.modelData.cpu.toFixed(1)
            : procRow.modelData.mem.toFixed(1)) + "%"
          color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
          font.family: Style.font.family
          font.pixelSize: 11
          width: parent.width * 0.25
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }
}
