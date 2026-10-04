import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WidgetModel.js" as Model
import "WidgetConfig.js" as Config
import "WidgetTheme.js" as Theme
import "GpuModel.js" as Gpu

// Temperature sensors card: flat list layout.
// Large hottest temp + status on the left, vertical divider,
// sensor readings (CPU/GPU/FAN) stacked on the right with color dots.
BorderSurface {
  id: root

  property string widgetId: "temperature"
  property var config: ({})
  property color cardColor: Qt.rgba(0.09, 0.09, 0.10, 0.95)
  property color borderColor: Qt.rgba(1, 1, 1, 0.12)
  property color textColor: Color.foreground
  property color accentColor: Color.accent
  property real cardRadius: 18
  property real gaugeDiameter: 120
  property var gpuMonitor: null
  readonly property var gpuDevices: root.gpuMonitor ? root.gpuMonitor.devices : []
  readonly property string selectedGpuId: (Config.widgetConfig(root.config, "systemMonitor") || {}).gpuDevice || ""

  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property int refreshInterval: Config.widgetRefreshInterval(root.config, root.widgetId)
  readonly property var sensorList: root.widgetCfg.sensors || ["cpu", "gpu"]
  readonly property bool showFan: root.widgetCfg.showFan !== false
  readonly property string temperatureUnit: root.widgetCfg.unit === "fahrenheit" ? "fahrenheit" : "celsius"
  readonly property string unitSymbol: root.temperatureUnit === "fahrenheit" ? "°F" : "°C"
  readonly property bool compactLayout: root.width <= 240
  readonly property int contentSpacing: root.compactLayout ? 14 : 18
  readonly property int heroFontSize: root.compactLayout ? 34 : 38
  readonly property int detailFontSize: root.compactLayout ? 11 : 12

  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0
  readonly property real widgetGaugeDiameter: Number(root.widgetCfg.gaugeDiameter) || root.gaugeDiameter

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: 16

  width: widgetCardWidth > 0 ? widgetCardWidth : 240
  height: 110

  // --- State ---
  property var temps: []
  property real hottestTemp: 0
  property real animatedHottestTemp: 0
  property bool tempSampleReady: false
  property string hottestSensor: ""
  Behavior on animatedHottestTemp {
    enabled: root.tempSampleReady
    NumberAnimation { duration: 280; easing.type: Easing.OutCubic }
  }
  property int fanRpm: -1
  property bool fanChecked: false

  property string cpuTempPath: ""
  property bool cpuAvailable: false
  property bool gpuAvailable: false

  readonly property string tempStatus: Theme.resolveTempStatus(root.hottestTemp).toUpperCase()
  readonly property color tempColor: root.hottestSensor ? Theme.resolveTempGaugeColor(root.config, root.widgetId, root.hottestTemp, root.accentColor) : Theme.resolveMutedColor(root.textColor)

  function getTemp(name) {
    for (var i = 0; i < root.temps.length; i++) {
      if (root.temps[i].name === name) return root.temps[i].temp
    }
    return 0
  }
  function displayTemp(celsius) {
    var converted = Model.convertTemperature(celsius, root.temperatureUnit)
    return converted === null ? 0 : converted
  }

  function formatTemp(celsius) {
    return Math.round(root.displayTemp(celsius))
  }

  function refresh() {
    if (root.sensorList.indexOf("cpu") !== -1) {
      if (root.cpuTempPath) cpuTempFile.reload()
      else cpuFindProc.running = true
    }
    if (root.showFan && (!root.fanChecked || root.fanRpm >= 0)) fanProc.running = true
  }

  function recomputeAggregates() {
    var sensors = Array.isArray(root.sensorList) ? root.sensorList : []
    var max = -Infinity
    var maxName = ""
    for (var i = 0; i < root.temps.length; i++) {
      var reading = root.temps[i]
      var enabled = (reading.name === "CPU" && sensors.indexOf("cpu") !== -1 && root.cpuAvailable)
        || (reading.name === "GPU" && sensors.indexOf("gpu") !== -1 && root.gpuAvailable)
      var temp = Number(reading.temp)
      if (enabled && isFinite(temp) && temp > max) {
        max = temp
        maxName = reading.name
      }
    }
    if (max === -Infinity) {
      root.tempSampleReady = false
      root.animatedHottestTemp = 0
      root.hottestTemp = 0
      root.hottestSensor = ""
      return
    }
    root.animatedHottestTemp = max
    root.tempSampleReady = true
    root.hottestTemp = max
    root.hottestSensor = maxName
  }

  onSensorListChanged: {
    root.recomputeAggregates()
    root.refresh()
  }
  onGpuAvailableChanged: root.recomputeAggregates()
  onCpuAvailableChanged: root.recomputeAggregates()

  function updateCpuTemp(raw) {
    var n = Number(String(raw || "").trim())
    if (!isFinite(n) || n <= 0) {
      root.cpuAvailable = false
      root.cpuTempPath = ""
      root.recomputeAggregates()
      return
    }
    root.cpuAvailable = true
    setNamedTemp("CPU", n / 1000)
  }

  function updateGpuTemp() {
    var index = Gpu.selectedIndex(root.gpuDevices, root.selectedGpuId)
    var device = index >= 0 ? root.gpuDevices[index] : null
    root.gpuAvailable = !!(device && device.temp !== null)
    if (root.gpuAvailable) root.setGpuTemp(device.temp)
    else root.recomputeAggregates()
  }
  onGpuDevicesChanged: root.updateGpuTemp()
  onSelectedGpuIdChanged: root.updateGpuTemp()

  function setGpuTemp(tempC) { setNamedTemp("GPU", tempC) }

  function setNamedTemp(name, tempC) {
    var next = [], found = false
    for (var i = 0; i < root.temps.length; i++) {
      if (root.temps[i].name === name) { next.push({ name: name, temp: tempC }); found = true }
      else next.push(root.temps[i])
    }
    if (!found) next.push({ name: name, temp: tempC })
    root.temps = next
    root.recomputeAggregates()
  }

  function updateFan(raw) {
    root.fanChecked = true
    var n = Number(String(raw || "").trim())
    root.fanRpm = (isFinite(n) && n >= 0) ? Math.round(n) : -1
  }

  Process {
    id: cpuFindProc
    command: ["sh", "-c", "for z in /sys/class/thermal/thermal_zone*; do type=$(cat \"$z/type\" 2>/dev/null); if printf '%s\\n' \"$type\" | grep -Eqi '^(x86_pkg_temp|cpu[-_ ]?thermal|tcpu([_-].*)?|tctl|soc[_-]thermal|coretemp)$'; then if [ -r \"$z/temp\" ]; then echo \"$z/temp\"; exit 0; fi; fi; done; for n in /sys/class/hwmon/hwmon*/name; do name=$(cat \"$n\" 2>/dev/null); case \"$name\" in coretemp|k10temp|zenpower|cpu_thermal) if [ -r \"${n%/name}/temp1_input\" ]; then echo \"${n%/name}/temp1_input\"; exit 0; fi;; esac; done; for z in /sys/class/thermal/thermal_zone*; do type=$(cat \"$z/type\" 2>/dev/null); if printf '%s\\n' \"$type\" | grep -Eqi 'acpi|cpu|core'; then if [ -r \"$z/temp\" ]; then echo \"$z/temp\"; exit 0; fi; fi; done; echo ''"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: {
      root.cpuTempPath = String(text).trim()
      if (root.cpuTempPath) cpuTempFile.reload()
      else {
        root.cpuAvailable = false
        root.recomputeAggregates()
      }
    } }
  }

  FileView {
    id: cpuTempFile
    path: root.cpuTempPath
    watchChanges: false; printErrors: false
    onLoaded: root.updateCpuTemp(text())
    onLoadFailed: {
      root.cpuAvailable = false
      root.cpuTempPath = ""
      root.recomputeAggregates()
    }
  }

  Process {
    id: fanProc
    command: ["sh", "-c", "max=-1; for f in /sys/class/hwmon/*/fan*_input; do if [ -r \"$f\" ]; then val=$(cat \"$f\" 2>/dev/null); case \"$val\" in ''|*[!0-9]*) continue;; esac; if [ \"$val\" -gt \"$max\" ]; then max=$val; fi; fi; done; echo \"$max\""]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateFan(text) }
  }

  Timer {
    interval: root.refreshInterval; running: true; repeat: true
    onTriggered: root.refresh()
  }

  // Sleeping GPUs and sensors loaded after shell startup should recover, but
  // missing hardware should not cause a failed process every normal refresh.
  Timer {
    interval: 30000
    running: (root.sensorList.indexOf("cpu") !== -1 && !root.cpuAvailable)
      || (root.showFan && root.fanChecked && root.fanRpm < 0)
    repeat: true
    onTriggered: {
      if (root.sensorList.indexOf("cpu") !== -1 && !root.cpuAvailable && !cpuFindProc.running) cpuFindProc.running = true
      if (root.showFan && root.fanRpm < 0 && !fanProc.running) fanProc.running = true
    }
  }

  Component.onCompleted: root.refresh()

  // Layout: large temp + status on left | divider | sensor rows on right
  Row {
    id: content
    anchors.centerIn: parent
    spacing: root.contentSpacing

    // --- Left: hero temp + status ---
    Column {
      spacing: 4
      anchors.verticalCenter: parent.verticalCenter

      Row {
        spacing: 2
        anchors.horizontalCenter: parent.horizontalCenter

        Text {
          id: heroValue
          textFormat: Text.PlainText
          text: root.hottestSensor ? root.formatTemp(root.animatedHottestTemp) : "—"
          Accessible.role: Accessible.StaticText
          Accessible.name: root.hottestSensor ? "Hottest temperature " + root.formatTemp(root.hottestTemp) + root.unitSymbol : "Temperature unavailable"
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: root.heroFontSize
          font.weight: Font.DemiBold
        }

        Text {
          visible: root.hottestSensor !== ""
          textFormat: Text.PlainText
          text: root.unitSymbol
          color: Theme.resolveMutedColor(root.textColor)
          font.family: Style.font.family
          font.pixelSize: root.compactLayout ? 14 : 16
          font.weight: Font.Medium
          anchors.top: heroValue.top
          anchors.topMargin: root.compactLayout ? 4 : 5
        }
      }

      Text {
        textFormat: Text.PlainText
        text: root.hottestSensor ? root.tempStatus : "NO DATA"
        color: root.tempColor
        font.family: Style.font.family
        font.pixelSize: root.compactLayout ? 9 : 10
        font.weight: Font.Medium
        font.letterSpacing: root.compactLayout ? 1 : 1.5
        anchors.horizontalCenter: parent.horizontalCenter
        Behavior on color { ColorAnimation { duration: 300 } }
      }
    }

    // --- Vertical divider ---
    Rectangle {
      width: 1
      height: root.compactLayout ? 62 : 70
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.14)
      anchors.verticalCenter: parent.verticalCenter
    }

    // --- Right: sensor rows with color dots ---
    Column {
      spacing: 7
      anchors.verticalCenter: parent.verticalCenter

      // CPU row
      Row {
        spacing: root.compactLayout ? 6 : 8
        visible: root.sensorList.indexOf("cpu") !== -1 && root.cpuAvailable
        Rectangle {
          width: 6; height: 6; radius: 3
          color: Theme.resolveTempColor(root.getTemp("CPU"))
          anchors.verticalCenter: parent.verticalCenter
          Behavior on color { ColorAnimation { duration: 300 } }
        }
        Text {
          textFormat: Text.PlainText
          text: "CPU  " + root.formatTemp(root.getTemp("CPU")) + root.unitSymbol
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: root.detailFontSize
          font.weight: Font.Medium
        }
      }

      // GPU row
      Row {
        spacing: root.compactLayout ? 6 : 8
        visible: root.sensorList.indexOf("gpu") !== -1 && root.gpuAvailable
        Rectangle {
          width: 6; height: 6; radius: 3
          color: Theme.resolveTempColor(root.getTemp("GPU"))
          anchors.verticalCenter: parent.verticalCenter
          Behavior on color { ColorAnimation { duration: 300 } }
        }
        Text {
          textFormat: Text.PlainText
          text: "GPU  " + root.formatTemp(root.getTemp("GPU")) + root.unitSymbol
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: root.detailFontSize
          font.weight: Font.Medium
        }
      }

      // Fan row
      Row {
        spacing: root.compactLayout ? 6 : 8
        visible: root.showFan && root.fanRpm >= 0
        Rectangle {
          width: 6; height: 6; radius: 3
          color: Theme.resolveMutedColor(root.textColor)
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          textFormat: Text.PlainText
          text: root.fanRpm >= 1000 ? "FAN  " + (root.fanRpm / 1000).toFixed(1) + "k" : "FAN  " + root.fanRpm
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: root.detailFontSize
          font.weight: Font.Medium
        }
      }
    }
  }
}
