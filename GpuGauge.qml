import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import "GpuModel.js" as Gpu

// Fixed-size GPU slot: names and availability never resize the system card.
Item {
  id: root
  objectName: "gpuGauge"
  property var devices: []
  property string selectedId: ""
  property var aliases: ({})
  property bool interactive: true
  property bool discoveryReady: false
  property real diameter: 110
  property color accentColor: Color.accent
  property color textColor: Color.foreground
  property color subTextColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.6)
  readonly property int selectedIndex: Gpu.selectedIndex(root.devices, root.selectedId)
  readonly property var device: root.selectedIndex >= 0 ? root.devices[root.selectedIndex] : null
  readonly property bool canSwitch: root.interactive && root.devices.length > 1
  property real wheelAngle: 0
  property real wheelPixels: 0
  property real swipeX: 0
  property real swipeY: 0
  property bool componentReady: false
  property bool transitioning: false
  property bool frontIsA: true
  property int requestedDirection: 0
  property int queuedDirection: 0
  property int slideDirection: 1
  property bool animationsEnabled: true
  readonly property var currentPage: root.frontIsA ? pageA : pageB
  readonly property var otherPage: root.frontIsA ? pageB : pageA
  property var incomingPage: null
  property var outgoingPage: null
  signal selected(string deviceId)

  width: root.diameter
  height: root.diameter + 78
  activeFocusOnTab: root.canSwitch
  Accessible.role: Accessible.ComboBox
  Accessible.name: root.device ? Gpu.displayName(root.device, root.aliases) + ", " + root.device.name + ", "
    + (root.device.utilization === null ? root.device.status : Math.round(root.device.utilization) + " percent") : "GPU unavailable"
  Accessible.description: "Scroll or drag horizontally to switch GPUs"
  Accessible.onIncreaseAction: root.switchGpu(1)
  Accessible.onDecreaseAction: root.switchGpu(-1)

  function switchGpu(step) {
    if (!root.canSwitch || step === 0) return
    var direction = step < 0 ? -1 : 1
    // Keep the current animation intact and retain only the latest extra step.
    // A wheel burst cannot repeatedly restart the animation or build a long queue.
    if (root.transitioning) { root.queuedDirection = direction; return }
    root.requestedDirection = direction
    root.selected(Gpu.cycleDevice(root.devices, root.selectedId, direction))
  }

  function updatePage(page) {
    page.device = root.device
    page.deviceIndex = root.selectedIndex
    page.deviceCount = root.devices.length
    page.accentColor = root.accentColor
  }

  function resetPages() {
    slide.stop()
    root.transitioning = true // Suppress the ring's value tween across devices.
    root.currentPage.x = 0
    root.currentPage.opacity = 1
    root.currentPage.visible = true
    root.otherPage.visible = false
    root.updatePage(root.currentPage)
    root.queuedDirection = root.requestedDirection = 0
    root.transitioning = false
  }

  function syncDevice(animate) {
    if (!root.componentReady) return
    var previous = root.currentPage.device
    if (!root.device || !previous || !animate || !root.animationsEnabled) {
      root.resetPages()
      return
    }
    if (root.device.id === previous.id) {
      root.updatePage(root.currentPage)
      return
    }
    // External settings changes during a slide are applied when it finishes.
    if (root.transitioning) return
    root.slideDirection = root.requestedDirection || (root.selectedIndex > root.currentPage.deviceIndex ? 1 : -1)
    root.requestedDirection = 0
    root.transitioning = true
    root.outgoingPage = root.currentPage
    root.incomingPage = root.otherPage
    root.updatePage(root.incomingPage)
    root.incomingPage.x = root.slideDirection * root.width
    root.incomingPage.opacity = 0
    root.incomingPage.visible = true
    root.frontIsA = !root.frontIsA
    slide.start()
  }

  function finishSlide() {
    root.outgoingPage.visible = false
    root.currentPage.x = 0
    root.currentPage.opacity = 1
    root.transitioning = false
    var direction = root.queuedDirection
    root.queuedDirection = 0
    if (root.device && root.currentPage.device && root.device.id !== root.currentPage.device.id)
      root.syncDevice(true)
    else if (direction && root.canSwitch) root.switchGpu(direction)
  }
  function scrollGpu(angle, pixels) {
    if (!root.canSwitch) return false
    wheelReset.restart()
    if (pixels !== 0) {
      root.wheelPixels += pixels
      if (Math.abs(root.wheelPixels) >= 40) {
        root.switchGpu(root.wheelPixels < 0 ? 1 : -1)
        root.wheelPixels = 0
      }
    } else {
      root.wheelAngle += angle
      if (Math.abs(root.wheelAngle) >= 120) {
        root.switchGpu(root.wheelAngle < 0 ? 1 : -1)
        root.wheelAngle = 0
      }
    }
    return true
  }
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) root.switchGpu(1)
    else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) root.switchGpu(-1)
    else return
    event.accepted = root.canSwitch
  }
  onCanSwitchChanged: {
    root.wheelAngle = root.wheelPixels = 0
    if (!root.canSwitch) root.queuedDirection = 0
  }
  onDeviceChanged: root.syncDevice(true)
  onAccentColorChanged: if (root.componentReady) root.currentPage.accentColor = root.accentColor
  onAnimationsEnabledChanged: if (!root.animationsEnabled && root.componentReady) root.resetPages()
  Component.onCompleted: { root.componentReady = true; root.syncDevice(false) }

  Item {
    anchors.fill: parent
    clip: true
    GpuPage {
      id: pageA
      current: root.frontIsA
      aliases: root.aliases
      discoveryReady: root.discoveryReady
      animateReadings: root.animationsEnabled && !root.transitioning
      diameter: root.diameter
      textColor: root.textColor
      subTextColor: root.subTextColor
    }
    GpuPage {
      id: pageB
      visible: false
      current: !root.frontIsA
      aliases: root.aliases
      discoveryReady: root.discoveryReady
      animateReadings: root.animationsEnabled && !root.transitioning
      diameter: root.diameter
      textColor: root.textColor
      subTextColor: root.subTextColor
    }
  }
  ParallelAnimation {
    id: slide
    onFinished: root.finishSlide()
    NumberAnimation {
      target: root.outgoingPage; property: "x"
      from: 0; to: -root.slideDirection * root.width
      duration: 240; easing.type: Easing.InOutCubic
    }
    NumberAnimation {
      target: root.incomingPage; property: "x"
      from: root.slideDirection * root.width; to: 0
      duration: 240; easing.type: Easing.InOutCubic
    }
    NumberAnimation {
      target: root.outgoingPage; property: "opacity"
      from: 1; to: 0
      duration: 240; easing.type: Easing.InOutQuad
    }
    NumberAnimation {
      target: root.incomingPage; property: "opacity"
      from: 0; to: 1
      duration: 240; easing.type: Easing.InOutQuad
    }
  }
  Rectangle {
    anchors.fill: parent
    anchors.margins: -3
    radius: 6
    color: "transparent"
    border.color: root.accentColor
    border.width: 1
    visible: root.activeFocus
  }
  HoverHandler { id: gaugeHover }
  Controls.ToolTip {
    id: gpuTooltip
    visible: gaugeHover.hovered && root.device !== null
    delay: 700
    text: root.device ? Gpu.displayName(root.device, root.aliases) + "\n" + root.device.name + "\n"
      + (Gpu.displayName(root.device, root.aliases) !== root.device.kind ? root.device.kind + " · " : "")
      + root.device.status : ""
    contentItem: Text {
      text: gpuTooltip.text
      textFormat: Text.PlainText
      color: root.textColor
      font.family: Style.font.family
      font.pixelSize: 11
    }
  }
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    enabled: root.canSwitch
    onWheel: function(event) {
      var pixels = Math.abs(event.pixelDelta.x) > Math.abs(event.pixelDelta.y) ? event.pixelDelta.x : event.pixelDelta.y
      var angle = Math.abs(event.angleDelta.x) > Math.abs(event.angleDelta.y) ? event.angleDelta.x : event.angleDelta.y
      event.accepted = root.scrollGpu(angle, pixels)
    }
  }
  DragHandler {
    id: swipe
    target: null
    enabled: root.canSwitch
    acceptedButtons: Qt.LeftButton
    onTranslationChanged: {
      if (active) { root.swipeX = activeTranslation.x; root.swipeY = activeTranslation.y }
    }
    onActiveChanged: {
      if (active) { root.swipeX = 0; root.swipeY = 0 }
      else if (Math.abs(root.swipeX) >= 28 && Math.abs(root.swipeX) > Math.abs(root.swipeY) * 1.3)
        root.switchGpu(root.swipeX < 0 ? 1 : -1)
    }
  }
  Repeater {
    model: [-1, 1]
    delegate: Rectangle {
      required property int modelData
      objectName: modelData < 0 ? "previousGpu" : "nextGpu"
      x: modelData < 0 ? -5 : root.width - 19
      y: root.diameter + 2
      width: 24; height: 24; radius: 6
      visible: root.canSwitch && (gaugeHover.hovered || root.activeFocus || activeFocus)
      color: activeFocus ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.15) : "transparent"
      activeFocusOnTab: root.canSwitch
      Accessible.role: Accessible.Button
      Accessible.name: modelData < 0 ? "Previous GPU" : "Next GPU"
      Accessible.onPressAction: root.switchGpu(modelData)
      Keys.onSpacePressed: root.switchGpu(modelData)
      Keys.onReturnPressed: root.switchGpu(modelData)
      Text {
        anchors.centerIn: parent
        text: parent.modelData < 0 ? "‹" : "›"
        font.pixelSize: 20
        color: root.textColor
      }
      TapHandler { onTapped: root.switchGpu(parent.modelData) }
    }
  }
  Timer {
    id: wheelReset
    interval: 250
    onTriggered: { root.wheelAngle = 0; root.wheelPixels = 0 }
  }
}
