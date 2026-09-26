import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WidgetModel.js" as Model
import "WidgetConfig.js" as Config

// Disk usage card: per-mount usage bars with size/used/avail.
BorderSurface {
  id: root

  property string widgetId: "diskUsage"
  property var config: ({})
  property color cardColor: Qt.rgba(0.09, 0.09, 0.10, 0.95)
  property color borderColor: Qt.rgba(1, 1, 1, 0.12)
  property color textColor: Color.foreground
  property color accentColor: Color.accent
  property real cardRadius: 18
  property real gaugeDiameter: 120

  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property int refreshInterval: Config.widgetRefreshInterval(root.config, root.widgetId)
  readonly property var mountFilter: Array.isArray(root.widgetCfg.mounts)
    ? root.widgetCfg.mounts : []
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0
  readonly property var diskCommand: {
    var args = ["env", "LC_ALL=C", "df", "-h", "--output=target,size,used,avail,pcent,source"]
    if (root.mountFilter.length > 0) args.push("--")
    for (var i = 0; i < root.mountFilter.length; i++) {
      var mount = String(root.mountFilter[i] || "").trim()
      if (mount) args.push(mount)
    }
    return args
  }

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: 20

  width: widgetCardWidth > 0 ? widgetCardWidth : 300
  height: content.implicitHeight + 40


  property var disks: []
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
    if (diskProc.running) {
      root.refreshQueued = true
      return
    }
    root.pendingStdout = ""
    root.pendingStderr = ""
    root.pendingExitCode = -1
    root.stdoutReady = false
    root.stderrReady = false
    root.exitReady = false
    diskProc.running = true
  }

  function finishRefresh() {
    if (!root.stdoutReady || !root.stderrReady || !root.exitReady) return
    root.exitReady = false
    root.hasLoaded = true
    if (root.pendingExitCode === 0) {
      root.updateDisks(root.pendingStdout)
      root.errorMessage = ""
    } else {
      root.errorMessage = root.pendingStderr.trim() || "Unable to read disk usage"
    }
    if (root.refreshQueued) {
      root.refreshQueued = false
      Qt.callLater(root.refresh)
    }
  }

  function updateDisks(raw) {
    disks = Model.parseDiskUsage(raw, root.mountFilter)
  }

  Process {
    id: diskProc
    command: root.diskCommand
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
  onMountFilterChanged: Qt.callLater(function() { root.refresh() })

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
      text: "DISK USAGE"
      color: root.textColor
      font.family: Style.font.family
      font.pixelSize: 12
      font.bold: true
      font.letterSpacing: 1.5
    }

    Text {
      width: parent.width
      visible: !root.hasLoaded && root.disks.length === 0
      textFormat: Text.PlainText
      text: "Loading disk usage..."
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
      visible: root.hasLoaded && root.errorMessage === "" && root.disks.length === 0
      textFormat: Text.PlainText
      text: root.mountFilter.length > 0 ? "No matching filesystems" : "No filesystems found"
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
      font.family: Style.font.family
      font.pixelSize: 11
    }

    Repeater {
      model: root.disks

      Column {
        id: diskRow
        required property var modelData
        required property int index

        width: content.width
        spacing: 4

        Row {
          width: parent.width
          spacing: 0

          Text {
            textFormat: Text.PlainText
            text: diskRow.modelData.mount
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: 11
            font.bold: true
            elide: Text.ElideRight
            width: parent.width * 0.5
          }

          Text {
            textFormat: Text.PlainText
            text: diskRow.modelData.used + " / " + diskRow.modelData.size
            color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
            font.family: Style.font.family
            font.pixelSize: 10
            horizontalAlignment: Text.AlignRight
            width: parent.width * 0.5
          }
        }

        // Usage bar
        Item {
          width: parent.width
          height: 6

          Rectangle {
            anchors.fill: parent
            radius: 3
            color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.08)
          }

          Rectangle {
            width: parent.width * (diskRow.modelData.percent / 100)
            height: parent.height
            radius: 3
            color: diskRow.modelData.percent > 90 ? Color.urgent : root.accentColor

            Behavior on width {
              NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          text: diskRow.modelData.percent + "% used · " + diskRow.modelData.avail + " free"
          color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.4)
          font.family: Style.font.family
          font.pixelSize: 9
        }
      }
    }
  }
}
