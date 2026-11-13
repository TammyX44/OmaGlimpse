import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/GpuModel.js" as Gpu

// One cached sysfs reader per device. Intel's optional tool streams samples,
// instead of starting a new perf-counter process for every refresh.
Item {
  id: root
  required property var device
  property bool pollingEnabled: false
  property int refreshInterval: 3000
  signal sampled(string deviceId, var reading)

  property bool sleeping: false
  property bool runtimeReady: false
  property real busy: -1
  property real temperature: -1
  property real memUsed: -1
  property real memTotal: -1
  property real intelBusy: -1
  property real intelObservedAt: 0
  property bool intelFailed: false
  property bool intelRestarting: false
  property var intelColumns: []

  function number(raw, divisor) {
    var value = Gpu.optionalNumber(String(raw).trim())
    return value === null ? -1 : value / divisor
  }

  function publish() {
    var utilization = root.device.vendor === "intel"
      ? (Date.now() - root.intelObservedAt <= Math.max(10000, root.refreshInterval * 3) ? root.intelBusy : -1)
      : root.busy
    root.sampled(root.device.id, { sleeping: root.sleeping, runtimeReady: root.runtimeReady,
      utilization: utilization < 0 ? null : Math.min(100, utilization),
      temp: root.temperature < 0 ? null : root.temperature,
      memUsed: root.memUsed < 0 ? null : root.memUsed,
      memTotal: root.memTotal < 0 ? null : root.memTotal, observedAt: Date.now() })
  }

  function readMetrics() {
    if (!root.pollingEnabled || root.sleeping) return
    if (root.device.tempPath) tempFile.reload()
    if (root.device.busyPath) busyFile.reload()
    if (root.device.memUsedPath) usedFile.reload()
    if (root.device.memTotalPath) totalFile.reload()
    root.publish()
  }

  function refresh() {
    if (!root.pollingEnabled) return
    if (root.device.runtimePath) runtimeFile.reload()
    else { root.runtimeReady = true; root.readMetrics() }
  }

  onPollingEnabledChanged: {
    if (pollingEnabled) Qt.callLater(root.refresh)
    else { root.intelBusy = -1; root.intelObservedAt = 0; root.intelColumns = [] }
  }
  onRefreshIntervalChanged: if (intelProc.running) root.intelRestarting = true
  Component.onCompleted: root.refresh()

  FileView {
    id: runtimeFile
    path: root.pollingEnabled ? root.device.runtimePath : ""
    watchChanges: false
    printErrors: false
    onLoaded: {
      root.runtimeReady = true
      var status = text().trim()
      root.sleeping = status === "suspended" || status === "suspending"
      if (root.sleeping) {
        root.busy = root.temperature = root.memUsed = root.memTotal = root.intelBusy = -1
        root.intelObservedAt = 0
        root.publish()
      } else root.readMetrics()
    }
    onLoadFailed: { root.runtimeReady = true; root.sleeping = false; root.readMetrics() }
  }
  FileView {
    id: busyFile
    path: root.pollingEnabled && root.runtimeReady && !root.sleeping ? root.device.busyPath : ""
    watchChanges: false; printErrors: false
    onLoaded: { root.busy = root.number(text(), 1); root.publish() }
    onLoadFailed: { root.busy = -1; root.publish() }
  }
  FileView {
    id: tempFile
    path: root.pollingEnabled && root.runtimeReady && !root.sleeping ? root.device.tempPath : ""
    watchChanges: false; printErrors: false
    onLoaded: { root.temperature = root.number(text(), 1000); root.publish() }
    onLoadFailed: { root.temperature = -1; root.publish() }
  }
  FileView {
    id: usedFile
    path: root.pollingEnabled && root.runtimeReady && !root.sleeping ? root.device.memUsedPath : ""
    watchChanges: false; printErrors: false
    onLoaded: { root.memUsed = root.number(text(), 1024 * 1024); root.publish() }
    onLoadFailed: { root.memUsed = -1; root.publish() }
  }
  FileView {
    id: totalFile
    path: root.pollingEnabled && root.runtimeReady && !root.sleeping ? root.device.memTotalPath : ""
    watchChanges: false; printErrors: false
    onLoaded: { root.memTotal = root.number(text(), 1024 * 1024); root.publish() }
    onLoadFailed: { root.memTotal = -1; root.publish() }
  }

  Process {
    id: intelProc
    command: ["intel_gpu_top", "-c", "-s", String(root.refreshInterval), "-d", "drm:/dev/dri/" + root.device.cardPath.split("/").pop()]
    running: root.pollingEnabled && root.runtimeReady && !root.sleeping
      && root.device.vendor === "intel" && root.device.intelTool && !root.intelFailed
      && !root.intelRestarting
    stdout: SplitParser {
      onRead: function(data) {
        var line = String(data).trim()
        if (line === "") return
        // Take the header once per process; any later line with letters (nan, a
        // warning) is skipped instead of wiping the columns.
        if (Gpu.isIntelCsvHeader(line)) {
          if (!root.intelColumns.length) root.intelColumns = Gpu.intelCsvColumns(line)
          return
        }
        var value = Gpu.parseIntelCsv(line, root.intelColumns)
        if (value === null) return
        root.intelBusy = value
        root.intelObservedAt = Date.now()
        root.publish()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: {
      root.intelFailed = root.pollingEnabled && !root.sleeping && !root.intelRestarting
      root.intelColumns = []
      root.intelBusy = -1
      root.intelObservedAt = 0
      root.publish()
      root.intelRestarting = false
    }
  }
  Timer {
    interval: root.refreshInterval
    running: root.pollingEnabled
    repeat: true
    onTriggered: root.refresh()
  }
  Timer {
    interval: 30000
    running: root.pollingEnabled && root.intelFailed && root.device.intelTool && !root.sleeping
    repeat: true
    onTriggered: root.intelFailed = false
  }
}
