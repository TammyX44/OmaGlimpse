import QtQuick
import Quickshell
import Quickshell.Io
import "WidgetConfig.js" as Config
import "GpuModel.js" as Gpu

// Shared by the system and temperature cards. Inventory is refreshed slowly;
// readings use the shortest interval requested by the enabled consumers.
Item {
  id: root
  property var config: ({})
  property var discoveryCommand: ["sh", decodeURIComponent(Qt.resolvedUrl("gpu-discover.sh").toString().replace(/^file:\/\//, ""))]
  readonly property var systemCfg: Config.widgetConfig(root.config, "systemMonitor") || {}
  readonly property var temperatureCfg: Config.widgetConfig(root.config, "temperature") || {}
  readonly property bool systemEnabled: systemCfg.enabled === true && systemCfg.showGpu !== false
  readonly property bool temperatureEnabled: temperatureCfg.enabled === true
    && (!Array.isArray(temperatureCfg.sensors) || temperatureCfg.sensors.indexOf("gpu") !== -1)
  readonly property bool pollingEnabled: root.systemEnabled || root.temperatureEnabled
  readonly property int refreshInterval: Math.min(
    root.systemEnabled ? Config.widgetRefreshInterval(root.config, "systemMonitor") : 60000,
    root.temperatureEnabled ? Config.widgetRefreshInterval(root.config, "temperature") : 60000)
  property var inventory: []
  property var samples: ({})
  property var nvidiaSamples: ({})
  property real now: Date.now()
  property bool discoveryReady: false
  property real nvidiaRetryAfter: 0
  readonly property var devices: Gpu.resolveDevices(root.inventory, root.samples, root.nvidiaSamples,
    root.now, Math.max(10000, root.refreshInterval * 3))

  visible: false

  function discover() {
    if (root.pollingEnabled && !discoveryProc.running) discoveryProc.running = true
  }
  function acceptSample(deviceId, reading) {
    if (!root.pollingEnabled) return
    var next = Object.assign({}, root.samples)
    next[deviceId] = reading
    root.samples = next
    root.now = Date.now()
  }
  function refreshNvidia() {
    root.now = Date.now()
    if (!root.pollingEnabled || nvidiaProc.running || root.now < root.nvidiaRetryAfter) return
    var ids = root.inventory.filter(function(device) {
      var sample = root.samples[device.id]
      return device.vendor === "nvidia" && sample && sample.runtimeReady && !sample.sleeping
    }).map(function(device) { return device.id })
    if (!ids.length) return
    nvidiaProc.command = ["timeout", "5s", "nvidia-smi", "-i", ids.join(","),
      "--query-gpu=pci.bus_id,name,utilization.gpu,memory.used,memory.total,temperature.gpu", "--format=csv,noheader,nounits"]
    nvidiaProc.running = true
  }
  onPollingEnabledChanged: {
    if (pollingEnabled) root.discover()
    else {
      nvidiaProc.running = false
      root.nvidiaSamples = ({})
      root.samples = ({})
      root.nvidiaRetryAfter = 0
    }
  }
  Component.onCompleted: root.discover()

  Process {
    id: discoveryProc
    command: root.discoveryCommand
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Gpu.parseInventory(text)
        if (JSON.stringify(next) !== JSON.stringify(root.inventory)) {
          root.inventory = next
          root.nvidiaRetryAfter = 0
          var samples = {}, nvidia = {}
          next.forEach(function(device) {
            if (root.samples[device.id]) samples[device.id] = root.samples[device.id]
            if (root.nvidiaSamples[device.id]) nvidia[device.id] = root.nvidiaSamples[device.id]
          })
          root.samples = samples; root.nvidiaSamples = nvidia
        }
        root.discoveryReady = true
        root.now = Date.now()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }
  Repeater {
    model: root.inventory
    delegate: GpuDevice {
      required property var modelData
      device: modelData
      pollingEnabled: root.pollingEnabled
      refreshInterval: root.refreshInterval
      onSampled: function(deviceId, reading) {
        var wasReady = root.samples[deviceId] && root.samples[deviceId].runtimeReady
        root.acceptSample(deviceId, reading)
        if (!wasReady && reading.runtimeReady) Qt.callLater(root.refreshNvidia)
      }
    }
  }
  Process {
    id: nvidiaProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.pollingEnabled) return
        var readings = Gpu.parseNvidia(text), next = {}
        Object.keys(readings).forEach(function(id) {
          readings[id].observedAt = Date.now()
          next[id] = readings[id]
        })
        root.nvidiaSamples = next
        root.now = Date.now()
        root.nvidiaRetryAfter = Object.keys(next).length ? 0 : root.now + 30000
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }
  Timer {
    interval: root.refreshInterval
    running: root.pollingEnabled
    repeat: true
    onTriggered: root.refreshNvidia()
  }
  Timer {
    interval: 30000
    running: root.pollingEnabled
    repeat: true
    onTriggered: root.discover()
  }
}
