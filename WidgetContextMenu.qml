import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "WidgetConfig.js" as Config

// Right-click context menu for widget cards.
// Appears at cursor position, provides quick access to:
//   - Enable/disable this widget
//   - Reset position (back to auto-layout)
//   - Refresh rate presets
//   - Widget-specific toggles
//   - "Open full settings" → opens settings panel

PanelWindow {
  id: menu

  property string widgetId: ""
  property var config: ({})
  property bool editMode: false
  property color cardColor: Color.popups.background
  property color borderColor: Color.popups.border
  property color textColor: Color.popups.text
  property color accentColor: Color.accent

  signal widgetConfigChanged(string widgetId, string key, var value)
  signal openSettings()
  signal editModeToggleRequested()

  visible: false
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "tammy.widgets.menu"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: menu.visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

  // Full-screen surface so screen-space menu coordinates remain valid and
  // the outside-click handler can dismiss the menu anywhere on the screen.
  anchors { top: true; bottom: true; left: true; right: true }

  property real menuX: 0
  property real menuY: 0
  readonly property real menuMargin: 8
  readonly property real clampedMenuX: Math.max(menuMargin,
    Math.min(menuX, Math.max(menuMargin, width - menuCard.width - menuMargin)))
  readonly property real clampedMenuY: Math.max(menuMargin,
    Math.min(menuY, Math.max(menuMargin, height - menuCard.height - menuMargin)))

  function show(x, y) {
    menuX = x
    menuY = y
    visible = true
    Qt.callLater(function() { enableWidgetRow.forceActiveFocus() })
  }

  function hide() {
    visible = false
  }

  readonly property var widgetCfg: Config.widgetConfig(menu.config, menu.widgetId) || {}
  readonly property int currentInterval: Config.widgetRefreshInterval(menu.config, menu.widgetId)

  function setConfig(key, value) {
    widgetConfigChanged(widgetId, key, value)
  }

  function setRefreshRate(ms) {
    setConfig("refreshInterval", ms)
    hide()
  }

  function toggleEnabled() {
    var w = Config.widgetConfig(menu.config, menu.widgetId)
    setConfig("enabled", !(w && w.enabled))
    hide()
  }

  function resetPosition() {
    setConfig("x", -1)
    setConfig("y", -1)
    hide()
  }

  Item {
    id: keyCatcher
    anchors.fill: parent
    z: -1
    focus: menu.visible
    Keys.onEscapePressed: menu.hide()
  }

  // Dismiss on outside click
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: menu.hide()
  }

  BorderSurface {
    id: menuCard
    x: menu.clampedMenuX
    y: menu.clampedMenuY
    width: 220
    height: menuContent.implicitHeight + menuCard.padding * 2
    z: 1
    color: menu.cardColor
    borderSpec: Border.surfaceSpec("menu", "border", menu.borderColor, 1)
    radius: 12
    padding: 8

    Column {
      id: menuContent
      anchors.fill: parent
      anchors.margins: menuCard.padding
      spacing: 2

      Text {
        textFormat: Text.PlainText
        text: Config.widgetDisplayName(menu.widgetId)
        color: menu.textColor
        font.family: Style.font.family
        font.pixelSize: 12
        font.bold: true
        font.letterSpacing: 1
        leftPadding: 8
        topPadding: 4
        bottomPadding: 4
      }

      MenuDivider {}

      MenuRow {
        id: enableWidgetRow
        text: Config.widgetEnabled(menu.config, menu.widgetId) ? "Disable widget" : "Enable widget"
        textColor: menu.accentColor
        onTriggered: menu.toggleEnabled()
      }

      MenuRow {
        text: "Reset position to auto"
        onTriggered: menu.resetPosition()
      }

      MenuRow {
        text: menu.editMode ? "Exit edit mode" : "Enter edit mode"
        textColor: menu.accentColor
        onTriggered: { menu.editModeToggleRequested(); menu.hide() }
      }

      MenuDivider {}

      MenuRow {
        visible: menu.widgetId === "battery"
        text: "Show battery power"
        checkable: true
        checked: menu.widgetCfg.showPower !== false
        onTriggered: menu.setConfig("showPower", !checked)
      }

      Column {
        width: parent.width
        spacing: 2
        visible: menu.widgetId !== "battery" && menu.widgetId !== "media"
      Text {
        textFormat: Text.PlainText
        text: "REFRESH RATE"
        color: Qt.rgba(menu.textColor.r, menu.textColor.g, menu.textColor.b, 0.4)
        font.family: Style.font.family
        font.pixelSize: 9
        font.bold: true
        font.letterSpacing: 1
        leftPadding: 8
        topPadding: 4
      }

      MenuRow {
        text: "Fast (1s)"
        checkable: true
        checked: menu.currentInterval === 1000
        onTriggered: menu.setRefreshRate(1000)
      }
      MenuRow {
        text: "Medium (3s)"
        checkable: true
        checked: menu.currentInterval === 3000
        onTriggered: menu.setRefreshRate(3000)
      }
      MenuRow {
        text: "Slow (10s)"
        checkable: true
        checked: menu.currentInterval === 10000
        onTriggered: menu.setRefreshRate(10000)
      }
      }

      MenuDivider {}

      MenuRow {
        text: "Open full settings…"
        textColor: menu.accentColor
        onTriggered: { menu.hide(); menu.openSettings() }
      }
    }
  }

  component MenuRow: Item {
    property string text: ""
    property color textColor: menu.textColor
    property bool checkable: false
    property bool checked: false
    signal triggered()

    width: parent.width
    height: 28
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        triggered()
        event.accepted = true
      } else if (event.key === Qt.Key_Escape) {
        menu.hide()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        var next = nextItemInFocusChain(true)
        if (next) next.forceActiveFocus()
        event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        var previous = nextItemInFocusChain(false)
        if (previous) previous.forceActiveFocus()
        event.accepted = true
      }
    }
    Accessible.onPressAction: triggered()

    activeFocusOnTab: true
    Accessible.role: Accessible.MenuItem
    Accessible.name: text
    Accessible.checkable: checkable
    Accessible.checked: checked

    Rectangle {
      anchors.fill: parent
      color: parent.checked
        ? Qt.rgba(menu.accentColor.r, menu.accentColor.g, menu.accentColor.b, 0.15)
        : (hover.hovered ? Qt.rgba(menu.textColor.r, menu.textColor.g, menu.textColor.b, 0.06) : "transparent")
      radius: 6
      border.width: parent.activeFocus ? 1 : 0
      border.color: menu.accentColor
    }

    HoverHandler { id: hover }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: parent.text
      color: parent.checked ? menu.accentColor : parent.textColor
      font.family: Style.font.family
      font.pixelSize: 11
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "✓"
      color: menu.accentColor
      font.family: Style.font.family
      font.pixelSize: 11
      visible: parent.checked
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        parent.forceActiveFocus()
        parent.triggered()
      }
    }
  }

  component MenuDivider: Rectangle {
    width: parent.width
    height: 1
    color: Qt.rgba(menu.textColor.r, menu.textColor.g, menu.textColor.b, 0.08)
  }
}
