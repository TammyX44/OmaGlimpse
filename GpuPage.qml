import QtQuick
import qs.Commons
import "GpuModel.js" as Gpu

// One complete carousel page. The outgoing page keeps its last device sample
// while the incoming page moves into place, so names and readings travel together.
Item {
  id: root
  property var device: null
  property int deviceIndex: -1
  property int deviceCount: 0
  property var aliases: ({})
  property bool current: false
  property bool discoveryReady: false
  property bool animateReadings: true
  property real diameter: 110
  property color accentColor: Color.accent
  property color textColor: Color.foreground
  property color subTextColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.6)

  width: root.diameter
  height: root.diameter + 78

  CircularGauge {
    objectName: "gpuRing"
    value: root.device && root.device.utilization !== null ? root.device.utilization : 0
    displayText: root.device && root.device.utilization !== null ? "" : "—"
    label: root.deviceCount > 1 ? "GPU " + (root.deviceIndex + 1) + "/" + root.deviceCount : "GPU"
    animateValue: root.animateReadings
    diameter: root.diameter
    accentColor: root.accentColor
    textColor: root.textColor
    subTextColor: root.subTextColor
  }
  Text {
    objectName: root.current ? "gpuDeviceName" : ""
    y: root.diameter + 27
    width: parent.width
    height: 16
    textFormat: Text.PlainText
    text: root.device ? Gpu.displayName(root.device, root.aliases) : root.discoveryReady ? "No GPU detected" : "Detecting…"
    color: root.textColor
    font.family: Style.font.family
    font.pixelSize: root.diameter < 64 ? 9 : 11
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
  }
  Text {
    objectName: root.current ? "gpuDeviceDetail" : ""
    y: root.diameter + 45
    width: parent.width
    height: 16
    textFormat: Text.PlainText
    text: root.device ? root.device.name : ""
    color: root.subTextColor
    font.family: Style.font.family
    font.pixelSize: root.diameter < 64 ? 8 : 10
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
  }
  Text {
    objectName: root.current ? "gpuDeviceStatus" : ""
    y: root.diameter + 61
    width: parent.width
    height: 16
    textFormat: Text.PlainText
    text: !root.device ? "" : root.device.status === "Ready"
      ? (root.device.temp === null ? "Active" : Math.round(root.device.temp) + "°C") : root.device.status
    color: root.subTextColor
    font.family: Style.font.family
    font.pixelSize: root.diameter < 64 ? 8 : 10
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
  }
}
