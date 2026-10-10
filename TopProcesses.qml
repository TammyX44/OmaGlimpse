import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ProcessModel.js" as Model
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
  property bool samplingEnabled: true
  property real samplingMultiplier: 1
  readonly property int samplingInterval: Model.samplingInterval(root.refreshInterval, root.samplingMultiplier)
  property var snapshotCommand: ["python3", decodeURIComponent(String(Qt.resolvedUrl("process_snapshot.py")).replace(/^file:\/\//, ""))]

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
  property bool componentReady: false
  property bool collectionActive: false
  property int sampleGeneration: 0
  property int requestGeneration: -1
  property var previousSnapshot: null
  property var sampledProcesses: []
  property bool sampleReady: false

  function resetBaseline() {
    root.sampleGeneration++
    root.previousSnapshot = null
    root.sampledProcesses = []
    root.processes = []
    root.sampleReady = false
    root.hasLoaded = false
    root.errorMessage = ""
    root.refreshQueued = false
    if (proc.running) proc.signal(15)
    if (root.componentReady && root.samplingEnabled) Qt.callLater(root.refresh)
  }

  function updateRanking() {
    root.processes = Model.topProcesses(root.sampledProcesses, root.sortBy, root.processCount)
  }

  function refresh() {
    if (!root.componentReady || !root.samplingEnabled) return
    // Wait for exit AND both streams, including after pause/resume cancellation.
    if (root.collectionActive) {
      root.refreshQueued = true
      return
    }
    root.pendingStdout = ""
    root.pendingStderr = ""
    root.pendingExitCode = -1
    root.stdoutReady = false
    root.stderrReady = false
    root.exitReady = false
    root.requestGeneration = root.sampleGeneration
    root.collectionActive = true
    proc.running = true
    collectorDeadline.restart()
  }

  function finishRefresh() {
    if (!root.stdoutReady || !root.stderrReady || !root.exitReady) return
    if (!root.collectionActive) return
    root.collectionActive = false
    collectorDeadline.stop()
    if (root.samplingEnabled && root.requestGeneration === root.sampleGeneration) {
      root.hasLoaded = true
      try {
        if (root.pendingExitCode !== 0)
          throw new Error(root.pendingStderr.trim().slice(0, 256) || "Unable to read process data")
        root.updateProcesses(root.pendingStdout)
        root.errorMessage = ""
      } catch (error) {
        root.previousSnapshot = null
        root.sampleReady = false
        root.sampledProcesses = []
        root.processes = []
        root.errorMessage = String(error.message || "Invalid process data")
      }
    }
    root.pendingStdout = ""
    root.pendingStderr = ""
    if (root.refreshQueued) {
      root.refreshQueued = false
      Qt.callLater(root.refresh)
    }
  }

  function updateProcesses(raw) {
    var snapshot = Model.parseSnapshot(raw)
    var result = Model.sample(snapshot, root.previousSnapshot)
    root.previousSnapshot = snapshot
    root.sampledProcesses = result.processes
    root.sampleReady = result.ready
    root.updateRanking()
  }

  Process {
    id: proc
    objectName: "processSamplingProcess"
    // The helper bounds records and output; timeout bounds its entire lifetime.
    command: ["timeout", "--signal=TERM", "--kill-after=0.2s", "3s"].concat(root.snapshotCommand)
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
    onExited: function(exitCode, exitStatus) {
      root.pendingExitCode = exitStatus === 0 ? exitCode : -1
      root.exitReady = true
      root.finishRefresh()
    }
  }

  Timer {
    id: sampleTimer
    objectName: "processSamplingTimer"
    interval: root.samplingInterval
    running: root.componentReady && root.samplingEnabled
    repeat: true
    onTriggered: root.refresh()
  }

  // Also recover if timeout itself cannot launch and no stream-finished event
  // arrives. A running timeout already owns the helper's termination deadline.
  Timer {
    id: collectorDeadline
    interval: 3500
    onTriggered: {
      // Do not let a late stream/exit from a cancelled collector become part
      // of a new request. GNU timeout forwards TERM and enforces kill-after.
      if (proc.running) {
        proc.signal(15)
        collectorDeadline.restart()
        return
      }
      root.pendingExitCode = -1
      root.pendingStderr = "Process collection timed out"
      root.stdoutReady = true
      root.stderrReady = true
      root.exitReady = true
      root.finishRefresh()
    }
  }

  Component.onCompleted: {
    root.componentReady = true
    root.refresh()
  }
  onSamplingEnabledChanged: root.resetBaseline()
  onSamplingIntervalChanged: {
    if (root.componentReady && root.samplingEnabled) {
      sampleTimer.restart()
      Qt.callLater(root.refresh)
    }
  }
  onProcessCountChanged: root.updateRanking()
  onSortByChanged: root.updateRanking()

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

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: !root.samplingEnabled ? "Sampling paused"
        : "CPU: 100% = one core" + (root.sampleReady ? "" : " · Measuring…")
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
      font.family: Style.font.family
      font.pixelSize: 9
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
      visible: root.samplingEnabled && !root.hasLoaded && root.processes.length === 0
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
      visible: root.samplingEnabled && root.hasLoaded && root.errorMessage === "" && root.processes.length === 0
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
            text: Model.formatPercent(root.sortBy === "mem"
              ? procRow.modelData.mem : procRow.modelData.cpu)
            color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.7)
            font.family: Style.font.family
            font.pixelSize: 11
            horizontalAlignment: Text.AlignRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          textFormat: Text.PlainText
          text: Model.formatPercent(root.sortBy === "mem"
            ? procRow.modelData.cpu : procRow.modelData.mem)
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
