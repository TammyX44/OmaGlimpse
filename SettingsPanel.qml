import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WidgetConfig.js" as Config
import "WidgetTheme.js" as Theme

// Full settings panel for the desktop widgets plugin.
// Opens as a centered overlay PanelWindow with a dark scrim.
// All changes write through signals back to Widgets.qml which persists them.
PanelWindow {
  id: panel

  property var config: ({})
  property color accentColor: Color.accent
  property color textColor: Color.foreground
  property color cardColor: Color.popups.background
  property color borderColor: Color.popups.border

  signal widgetConfigChanged(string widgetId, string key, var value)
  signal globalConfigChanged(string key, var value)
  signal colorConfigChanged(string key, var value)
  signal resetRequested()
  signal resetPositionsRequested()
  signal editModeToggleRequested()
  signal presetRequested(string preset)
  signal closeRequested()

  property bool editMode: false
  property string configError: ""
  property string colorInputError: ""
  property string layoutWarning: ""
  property string saveStatus: ""
  property bool externalConflict: false
  property bool resetArmed: false
  signal retrySaveRequested()
  signal resolveConflictRequested(bool keepLocal)

  // Collapsible widget sections — map of widgetId → bool (expanded)
  property var expandedWidgets: ({})
  property int openRevision: 0
  property string scrollTargetWidget: ""
  property int menuRevision: 0
  function shallowClone(obj) {
    if (!obj || typeof obj !== "object") return obj
    var c = {}
    for (var k in obj) c[k] = obj[k]
    return c
  }

  function toggleExpand(wid) {
    var e = shallowClone(panel.expandedWidgets)
    e[wid] = !e[wid]
    panel.expandedWidgets = e
  }

  function isExpanded(wid) {
    return !!panel.expandedWidgets[wid]
  }
  function clampViewport() {
    var maxContentY = Math.max(0,
      settingsFlickable.contentHeight - settingsFlickable.height)
    settingsFlickable.contentY = Math.max(0,
      Math.min(settingsFlickable.contentY, maxContentY))
  }

  function scrollToRequestedWidget() {
    if (!panel.scrollTargetWidget) return
    var index = Config.allWidgetIds().indexOf(panel.scrollTargetWidget)
    var section = index >= 0 ? widgetRepeater.itemAt(index) : null
    if (!section) return
    var desired = section.y - 16
    var maxY = Math.max(0, settingsFlickable.contentHeight - settingsFlickable.height)
    settingsFlickable.contentY = Math.max(0, Math.min(desired, maxY))
  }

  function settleVisiblePanel(revision) {
    if (!panel.visible || (revision !== undefined && revision !== panel.openRevision)) return
    settingsFlickable.cancelFlick()
    settingsFlickable.contentY = 0
    settingsFlickable.returnToBounds()
    panel.clampViewport()
    panel.scrollToRequestedWidget()
    settingsCard.forceActiveFocus()
  }

  function finiteNumber(value, fallback) {
    if (value === null || value === undefined || value === "") return fallback
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }

  function globalValue(key, fallback) {
    var global = panel.config ? panel.config.global : null
    return finiteNumber(global ? global[key] : undefined, fallback)
  }

  function colorValue(key, fallback) {
    var colors = panel.config ? panel.config.colors : null
    return finiteNumber(colors ? colors[key] : undefined, fallback)
  }

  function widgetNumber(widget, key, fallback) {
    return finiteNumber(widget ? widget[key] : undefined, fallback)
  }


  function globalBool(key, fallback) {
    var global = panel.config ? panel.config.global : null
    var value = global ? global[key] : undefined
    return typeof value === "boolean" ? value : fallback
  }

  function coordinateText(widgetId, key) {
    var value = key === "x"
      ? Config.widgetX(panel.config, widgetId)
      : Config.widgetY(panel.config, widgetId)
    return value >= 0 ? String(Math.round(value)) : ""
  }

  function commitCoordinate(field, widgetId, key) {
    var raw = String(field.text || "").trim()
    if (raw === "") {
      panel.widgetConfigChanged(widgetId, key, -1)
      return
    }

    var value = Number(raw)
    if (!isFinite(value) || value < 0) {
      field.text = panel.coordinateText(widgetId, key)
      return
    }

    panel.widgetConfigChanged(widgetId, key, Math.round(value))
  }

  function commitColorField(value, key, label) {
    var normalized = Theme.normalizeHex(value)
    if (!normalized) {
      panel.colorInputError = label + " must be #RRGGBB or #RRGGBBAA."
      return
    }
    panel.colorInputError = ""
    panel.colorConfigChanged(key, normalized)
  }


  function resetWidgetPosition(widgetId) {
    panel.widgetConfigChanged(widgetId, "x", -1)
    panel.widgetConfigChanged(widgetId, "y", -1)
  }

  visible: false
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "io.github.tammyx44.omawidgets.settings"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: panel.visible
    ? WlrKeyboardFocus.Exclusive
    : WlrKeyboardFocus.None

  onVisibleChanged: {
    panel.resetArmed = false
    panel.openRevision += 1
    if (visible) {
      settingsFlickable.cancelFlick()
      settingsFlickable.contentY = 0
      var revision = panel.openRevision
      Qt.callLater(function() { panel.settleVisiblePanel(revision) })
    } else {
      panel.menuRevision += 1
      widgetScrollSettle.stop()
      panel.scrollTargetWidget = ""
      settingsFlickable.cancelFlick()
    }
  }

  anchors { top: true; bottom: true; left: true; right: true }

  function show() { visible = true }
  function hide() { visible = false }

  function showWidgetSettings(widgetId) {
    if (Config.allWidgetIds().indexOf(widgetId) === -1) return
    var e = {}
    e[widgetId] = true
    panel.menuRevision += 1
    panel.expandedWidgets = e
    panel.scrollTargetWidget = widgetId
    Qt.callLater(function() { panel.scrollToRequestedWidget() })
    widgetScrollSettle.restart()
  }

  Timer {
    id: widgetScrollSettle
    interval: 250
    repeat: false
    onTriggered: {
      panel.scrollToRequestedWidget()
      panel.scrollTargetWidget = ""
    }
  }

  // --- Scrim background ---
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.5)

    MouseArea {
      anchors.fill: parent
      onClicked: panel.closeRequested()
    }
  }

  // --- Settings card ---
  BorderSurface {
    id: settingsCard
    anchors.centerIn: parent
    width: Math.min(560, Math.max(320, parent.width - 40))
    height: Math.min(820, parent.height - 40)
    color: panel.cardColor
    borderSpec: Border.surfaceSpec("settings", "border", panel.borderColor, 1)
    radius: 16
    padding: 0

    // Close on Escape
    Keys.onEscapePressed: panel.closeRequested()
    Keys.onPressed: function(event) {
      var page = Math.max(80, settingsFlickable.height * 0.8)
      if (event.key === Qt.Key_PageDown) {
        settingsFlickable.contentY += page
      } else if (event.key === Qt.Key_PageUp) {
        settingsFlickable.contentY -= page
      } else if (event.key === Qt.Key_Home) {
        settingsFlickable.contentY = 0
      } else if (event.key === Qt.Key_End) {
        settingsFlickable.contentY = settingsFlickable.contentHeight - settingsFlickable.height
      } else {
        return
      }
      panel.clampViewport()
      event.accepted = true
    }
    focus: true

    Column {
      id: cardContent
      anchors.fill: parent
      anchors.margins: 0
      spacing: 0

      // --- Header ---
      Rectangle {
        width: parent.width
        height: 52
        color: "transparent"

        Text {
          anchors.left: parent.left
          anchors.leftMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Desktop Widgets Settings"
          color: panel.textColor
          font.family: Style.font.family
          font.pixelSize: 16
          font.bold: true
        }

        Rectangle {
          id: closeButton
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          width: 36
          height: 36
          radius: 8
          color: closeHover.containsMouse || activeFocus
            ? Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.08)
            : "transparent"
          border.width: activeFocus ? 1 : 0
          border.color: panel.accentColor
          activeFocusOnTab: true
          Accessible.role: Accessible.Button
          Accessible.name: "Close widget settings"
          Accessible.onPressAction: panel.closeRequested()
          Keys.onReturnPressed: panel.closeRequested()
          Keys.onEnterPressed: panel.closeRequested()
          Keys.onSpacePressed: panel.closeRequested()

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "✕"
            color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
            font.family: Style.font.family
            font.pixelSize: 18
          }

          MouseArea {
            id: closeHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              closeButton.forceActiveFocus()
              panel.closeRequested()
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.08)
      }

      // --- Scrollable content ---
      Flickable {
        id: settingsFlickable
        width: parent.width
        height: parent.height - 52 - 1
        contentWidth: parent.width
        contentHeight: settingsColumn.implicitHeight + 60
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onContentHeightChanged: Qt.callLater(function() {
          if (panel.scrollTargetWidget) panel.scrollToRequestedWidget()
          else panel.clampViewport()
        })
        onHeightChanged: Qt.callLater(function() { panel.clampViewport() })

        onMovementEnded: panel.clampViewport()
        Column {
          id: settingsColumn
          width: parent.width - 40
          x: 20
          spacing: 16
          topPadding: 20

          Text {
            width: parent.width
            visible: panel.configError !== "" || panel.saveStatus !== ""
            text: panel.configError || panel.saveStatus
            textFormat: Text.PlainText
            color: panel.configError ? Color.urgent : panel.textColor
            font.family: Style.font.family
            font.pixelSize: 12
            wrapMode: Text.WordWrap
          }
          Row {
            spacing: 8
            visible: panel.configError !== ""
            Button {
              text: panel.externalConflict ? "Reload disk settings" : "Retry"
              focusable: true
              onClicked: panel.externalConflict ? panel.resolveConflictRequested(false) : panel.retrySaveRequested()
            }
            Button {
              visible: panel.externalConflict
              text: "Keep local changes"
              focusable: true
              onClicked: panel.resolveConflictRequested(true)
            }
          }

          Text {
            width: parent.width
            visible: panel.layoutWarning !== ""
            text: panel.layoutWarning
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: 12
            wrapMode: Text.WordWrap
          }

          // ===== GENERAL =====
          PanelSectionHeader {
            text: "GENERAL"
            width: parent.width
          }

          // Card radius
          Row {
            width: parent.width
            spacing: 12
            height: 36

            Text {
              textFormat: Text.PlainText
              text: "Card Radius"
              color: panel.textColor
              font.family: Style.font.family
              font.pixelSize: 13
              width: 120
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelSlider {
              width: parent.width - 120 - 50 - 24
              height: 36
              value: panel.globalValue("cardRadius", 18)
              minimum: 0
              maximum: 30
              step: 1
              integer: true
              onMoved: panel.globalConfigChanged("cardRadius", Math.round(value))
            }

            Text {
              textFormat: Text.PlainText
              text: panel.globalValue("cardRadius", 18) + "px"
              width: 50
              color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
              font.family: Style.font.family
              font.pixelSize: 12
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Card spacing
          Row {
            width: parent.width
            spacing: 12
            height: 36

            Text {
              textFormat: Text.PlainText
              text: "Card Spacing"
              color: panel.textColor
              font.family: Style.font.family
              font.pixelSize: 13
              width: 120
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelSlider {
              width: parent.width - 120 - 50 - 24
              height: 36
              value: panel.globalValue("cardSpacing", 12)
              minimum: 4
              maximum: 24
              step: 1
              integer: true
              onMoved: panel.globalConfigChanged("cardSpacing", Math.round(value))
            }

            Text {
              textFormat: Text.PlainText
              text: panel.globalValue("cardSpacing", 12) + "px"
              width: 50
              color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
              font.family: Style.font.family
              font.pixelSize: 12
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Liquid glass blur toggle
          Toggle {
            width: parent.width
            label: "Liquid glass blur"
            description: "Blur the wallpaper behind cards for a frosted glass effect."
            checked: panel.globalBool("blurEnabled", true)
            onClicked: panel.globalConfigChanged("blurEnabled", !panel.globalBool("blurEnabled", true))
          }

          // Blur intensity slider
          Column {
            width: parent.width
            spacing: 4
            height: 58
            visible: panel.globalBool("blurEnabled", true)

            Text {
              textFormat: Text.PlainText
              text: "Glass transparency"
              color: panel.textColor
              font.family: Style.font.family
              font.pixelSize: 12
              width: parent.width
              height: 18
              verticalAlignment: Text.AlignVCenter
            }

            Row {
              width: parent.width
              height: 36
              spacing: 12

              PanelSlider {
                width: parent.width - 50 - 12
                height: 36
                value: panel.globalValue("blurIntensity", 50)
                minimum: 0
                maximum: 100
                step: 5
                integer: true
                onMoved: panel.globalConfigChanged("blurIntensity", Math.round(value))
              }

              Text {
                textFormat: Text.PlainText
                text: panel.globalValue("blurIntensity", 50) + "%"
                width: 50
                color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                font.family: Style.font.family
                font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          // Gauge color mode — global default
          Row {
            width: parent.width
            spacing: 12
            height: 36

            Text {
              textFormat: Text.PlainText
              text: "Gauge Colors"
              color: panel.textColor
              font.family: Style.font.family
              font.pixelSize: 13
              width: 120
              anchors.verticalCenter: parent.verticalCenter
            }

            // Segmented control: Semantic / Theme
            Row {
              id: globalGaugeOptions
              height: 30
              spacing: 0
              anchors.verticalCenter: parent.verticalCenter

              function choose(mode) {
                panel.globalConfigChanged("gaugeColorMode", mode)
              }
              function focusMode(mode) {
                if (mode === "semantic") globalSemanticOption.forceActiveFocus()
                else globalThemeOption.forceActiveFocus()
              }
              property string currentMode: (panel.config.global && panel.config.global.gaugeColorMode) || "semantic"

              Rectangle {
                id: globalSemanticOption
                activeFocusOnTab: true
                Accessible.role: Accessible.RadioButton
                Accessible.name: "Semantic gauge colors"
                Accessible.checkable: true
                Accessible.checked: globalGaugeOptions.currentMode === "semantic"
                width: 80; height: 30
                radius: 6
                color: parent.currentMode === "semantic"
                  ? Qt.rgba(panel.accentColor.r, panel.accentColor.g, panel.accentColor.b, 0.25)
                  : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.05)
                border.color: parent.currentMode === "semantic" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.08)
                border.width: 1
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                    globalGaugeOptions.choose("accent")
                    globalGaugeOptions.focusMode("accent")
                  } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                    globalGaugeOptions.choose("semantic")
                    globalGaugeOptions.focusMode("semantic")
                  } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    globalGaugeOptions.choose("semantic")
                  } else return
                  event.accepted = true
                }
                Accessible.onPressAction: globalGaugeOptions.choose("semantic")

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "Semantic"
                  color: parent.parent.currentMode === "semantic" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                  font.family: Style.font.family
                  font.pixelSize: 11
                  font.bold: parent.parent.currentMode === "semantic"
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: panel.globalConfigChanged("gaugeColorMode", "semantic")
                }
              }

              Rectangle {
                id: globalThemeOption
                activeFocusOnTab: true
                Accessible.role: Accessible.RadioButton
                Accessible.name: "Theme gauge colors"
                Accessible.checkable: true
                Accessible.checked: globalGaugeOptions.currentMode === "accent"
                width: 80; height: 30
                radius: 6
                color: parent.currentMode === "accent"
                  ? Qt.rgba(panel.accentColor.r, panel.accentColor.g, panel.accentColor.b, 0.25)
                  : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.05)
                border.color: parent.currentMode === "accent" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.08)
                border.width: 1
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                    globalGaugeOptions.choose("semantic")
                    globalGaugeOptions.focusMode("semantic")
                  } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                    globalGaugeOptions.choose("accent")
                    globalGaugeOptions.focusMode("accent")
                  } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    globalGaugeOptions.choose("accent")
                  } else return
                  event.accepted = true
                }
                Accessible.onPressAction: globalGaugeOptions.choose("accent")

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "Theme"
                  color: parent.parent.currentMode === "accent" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                  font.family: Style.font.family
                  font.pixelSize: 11
                  font.bold: parent.parent.currentMode === "accent"
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: panel.globalConfigChanged("gaugeColorMode", "accent")
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: {
                var m = (panel.config.global && panel.config.global.gaugeColorMode) || "semantic"
                return m === "semantic" ? "Green→Red by load" : "Follow theme accent"
              }
              color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
              font.family: Style.font.family
              font.pixelSize: 11
              width: parent.width - 120 - 180 - 24
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Edit mode toggle
          Toggle {
            width: parent.width
            label: "Edit mode"
            description: "When ON: cards show a border and can be dragged. When OFF: cards are locked in place."
            checked: panel.editMode
            onClicked: panel.editModeToggleRequested()
          }

          // Position presets
          Text {
            textFormat: Text.PlainText
            text: "Position presets"
            color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
            font.family: Style.font.family
            font.pixelSize: 12
            width: parent.width
            topPadding: 4
          }

          Row {
            width: parent.width
            spacing: 8
            height: 32
            readonly property real cellWidth: (width - spacing * 2) / 3

            Button {
              width: parent.cellWidth
              height: parent.height
              text: "Left"
              bordered: true
              onClicked: panel.presetRequested("left")
            }
            Button {
              width: parent.cellWidth
              height: parent.height
              text: "Right"
              bordered: true
              onClicked: panel.presetRequested("right")
            }
            Button {
              width: parent.cellWidth
              height: parent.height
              text: "Top"
              bordered: true
              onClicked: panel.presetRequested("top")
            }
          }

          Row {
            width: parent.width
            spacing: 8
            height: 32
            readonly property real cellWidth: (width - spacing * 2) / 3

            Button {
              width: parent.cellWidth
              height: parent.height
              text: "Bottom"
              bordered: true
              onClicked: panel.presetRequested("bottom")
            }
            Button {
              width: parent.cellWidth
              height: parent.height
              text: "Center"
              bordered: true
              onClicked: panel.presetRequested("center")
            }
            Button {
              width: parent.cellWidth
              height: parent.height
              text: "Spread"
              bordered: true
              onClicked: panel.presetRequested("spread")
            }
          }

          // Reset all positions
          Button {
            width: parent.width
            height: 36
            bordered: true
            leftAlign: true
            text: "Reset all positions to auto"
            iconText: "↺"
            onClicked: panel.resetPositionsRequested()
          }

          PanelSeparator { width: parent.width }

          // ===== APPEARANCE =====
          PanelSectionHeader {
            text: "APPEARANCE"
            width: parent.width
          }

          // Theme mode toggle
          Toggle {
            width: parent.width
            label: "Use custom colors"
            description: "When off, widgets follow the active Omarchy theme"
            checked: panel.config.themeMode === "custom"
            onClicked: panel.globalConfigChanged("themeMode", !checked ? "custom" : "theme")
          }

          // Custom color fields (visible only in custom mode)
          Column {
            width: parent.width
            spacing: 8

            // Accent color
            Row {
              width: parent.width
              spacing: 12
              height: 36
              visible: panel.config.themeMode === "custom"

              Text {
                textFormat: Text.PlainText
                text: "Accent"
                color: panel.textColor
                font.family: Style.font.family
                font.pixelSize: 13
                width: 120
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: 36
                height: 36
                radius: 6
                color: Theme.hexToColor(panel.config.colors && panel.config.colors.accent) || panel.accentColor
                border.color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.2)
                border.width: 1
                anchors.verticalCenter: parent.verticalCenter
              }

              TextField {
                width: 160
                height: 36
                text: (panel.config.colors && panel.config.colors.accent) || ""
                placeholderText: "#7aa2f7"
                Accessible.name: "Accent color"
                onEditingFinished: panel.commitColorField(text, "accent", "Accent")
              }
            }

            // Card background
            Row {
              width: parent.width
              spacing: 12
              height: 36
              visible: panel.config.themeMode === "custom"

              Text {
                textFormat: Text.PlainText
                text: "Card BG"
                color: panel.textColor
                font.family: Style.font.family
                font.pixelSize: 13
                width: 120
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: 36
                height: 36
                radius: 6
                color: Theme.hexToColor(panel.config.colors && panel.config.colors.cardBackground) || panel.cardColor
                border.color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.2)
                border.width: 1
                anchors.verticalCenter: parent.verticalCenter
              }

              TextField {
                width: 160
                height: 36
                text: (panel.config.colors && panel.config.colors.cardBackground) || ""
                placeholderText: "#1a1b26"
                Accessible.name: "Card background color"
                onEditingFinished: panel.commitColorField(text, "cardBackground", "Card background")
              }
            }

            // Text color
            Row {
              width: parent.width
              spacing: 12
              height: 36
              visible: panel.config.themeMode === "custom"

              Text {
                textFormat: Text.PlainText
                text: "Text"
                color: panel.textColor
                font.family: Style.font.family
                font.pixelSize: 13
                width: 120
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: 36
                height: 36
                radius: 6
                color: Theme.hexToColor(panel.config.colors && panel.config.colors.textColor) || panel.textColor
                border.color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.2)
                border.width: 1
                anchors.verticalCenter: parent.verticalCenter
              }

              TextField {
                width: 160
                height: 36
                text: (panel.config.colors && panel.config.colors.textColor) || ""
                placeholderText: "#a9b1d6"
                Accessible.name: "Widget text color"
                onEditingFinished: panel.commitColorField(text, "textColor", "Text color")
              }
            }

            // Border color
            Row {
              width: parent.width
              spacing: 12
              height: 36
              visible: panel.config.themeMode === "custom"

              Text {
                textFormat: Text.PlainText
                text: "Border"
                color: panel.textColor
                font.family: Style.font.family
                font.pixelSize: 13
                width: 120
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: 36
                height: 36

                radius: 6
                color: Theme.hexToColor(panel.config.colors && panel.config.colors.borderColor) || panel.borderColor
                border.color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.2)
                border.width: 1
                anchors.verticalCenter: parent.verticalCenter
              }

              TextField {
                width: 160
                height: 36
                text: (panel.config.colors && panel.config.colors.borderColor) || ""
                placeholderText: "#ffffff"
                Accessible.name: "Widget border color"
                onEditingFinished: panel.commitColorField(text, "borderColor", "Border color")
              }

            }

            Text {
              width: parent.width
              visible: panel.config.themeMode === "custom" && panel.colorInputError !== ""
              text: panel.colorInputError
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: 11
              wrapMode: Text.WordWrap
            }

            // Card opacity
            Row {
              width: parent.width
              spacing: 12
              height: 36

              Text {
                textFormat: Text.PlainText
                text: "Card Opacity"
                color: panel.textColor
                font.family: Style.font.family
                font.pixelSize: 13
                width: 120
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelSlider {
                width: parent.width - 120 - 50 - 24
                height: 36
                value: panel.colorValue("cardOpacity", 0.55)
                minimum: 0.3
                maximum: 1.0
                step: 0.02
                onMoved: panel.colorConfigChanged("cardOpacity", Math.round(value * 100) / 100)
              }

              Text {
                textFormat: Text.PlainText
                text: Math.round(panel.colorValue("cardOpacity", 0.55) * 100) + "%"
                width: 50
                color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                font.family: Style.font.family
                font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Border opacity
            Row {
              width: parent.width
              spacing: 12
              height: 36

              Text {
                textFormat: Text.PlainText
                text: "Border Opacity"
                color: panel.textColor
                font.family: Style.font.family
                font.pixelSize: 13
                width: 120
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelSlider {
                width: parent.width - 120 - 50 - 24
                height: 36
                value: panel.colorValue("borderOpacity", 0.12)
                minimum: 0
                maximum: 1.0
                step: 0.02
                onMoved: panel.colorConfigChanged("borderOpacity", Math.round(value * 100) / 100)
              }

              Text {
                textFormat: Text.PlainText
                text: Math.round(panel.colorValue("borderOpacity", 0.12) * 100) + "%"
                width: 50
                color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                font.family: Style.font.family
                font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ===== WIDGETS =====
          PanelSectionHeader {
            text: "WIDGETS"
            width: parent.width
          }

          Repeater {
            id: widgetRepeater
            model: Config.allWidgetIds()

            Column {
              id: widgetSection
              required property var modelData
              required property int index

              width: parent.width
              spacing: 4

              readonly property string wid: modelData
              readonly property var wcfg: Config.widgetConfig(panel.config, wid) || {}
              readonly property bool expanded: panel.isExpanded(wid)

              // Widget header row: expand chevron + name + enable toggle
              Rectangle {
                width: parent.width
                height: 32
                color: "transparent"
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: (widgetSection.expanded ? "Collapse " : "Expand ")
                  + Config.widgetDisplayName(widgetSection.wid)
                Keys.onReturnPressed: panel.toggleExpand(widgetSection.wid)
                Keys.onEnterPressed: panel.toggleExpand(widgetSection.wid)
                Keys.onSpacePressed: panel.toggleExpand(widgetSection.wid)

                MouseArea {
                  anchors.fill: parent
                  onClicked: panel.toggleExpand(widgetSection.wid)
                  cursorShape: Qt.PointingHandCursor
                }

                Row {
                  anchors.fill: parent
                  spacing: 8

                  Text {
                    textFormat: Text.PlainText
                    text: widgetSection.expanded ? "▼" : "▶"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.58)
                    font.family: Style.font.family
                    font.pixelSize: 9
                    anchors.verticalCenter: parent.verticalCenter
                    width: 12
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: Config.widgetDisplayName(widgetSection.wid)
                    color: widgetSection.wcfg.enabled !== false
                      ? panel.textColor
                      : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.58)
                    font.family: Style.font.family
                    font.pixelSize: 13
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 12 - 40 - 8
                    elide: Text.ElideRight
                  }
                }

                // Enable toggle (compact, always visible on the right)
                CompactToggle {
                  checked: widgetSection.wcfg.enabled !== false
                  textColor: panel.textColor
                  accentColor: panel.accentColor
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: 100

                  onToggled: panel.widgetConfigChanged(widgetSection.wid, "enabled", value)
                }
              }

              // Expanded settings (collapsible)
              Column {
                id: expandedSettings
                width: parent.width
                spacing: 4
                leftPadding: 20
                readonly property real rowWidth: Math.max(0, width - leftPadding - rightPadding)
                readonly property real labelWidth: 100
                visible: widgetSection.expanded

                // Position controls — X/Y fields + reset
                Row {
                  id: positionRow
                  width: expandedSettings.rowWidth
                  spacing: 8
                  height: 28

                  readonly property bool hasManualPosition:
                    Config.widgetX(panel.config, widgetSection.wid) >= 0
                    || Config.widgetY(panel.config, widgetSection.wid) >= 0

                  Text {
                    textFormat: Text.PlainText
                    text: "Position"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: expandedSettings.labelWidth
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Row {
                    id: positionControls
                    width: Math.max(0, parent.width - expandedSettings.labelWidth - parent.spacing)
                    height: parent.height
                    spacing: 8

                    Row {
                      width: 98
                      height: parent.height
                      spacing: 8

                      Text {
                        textFormat: Text.PlainText
                        text: "X"
                        width: 12
                        color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                        font.family: Style.font.family
                        font.pixelSize: 10
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      TextField {
                        width: 78
                        height: 28
                        font.pixelSize: 11
                        verticalAlignment: TextInput.AlignVCenter
                        text: panel.coordinateText(widgetSection.wid, "x")
                        placeholderText: "Auto"
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                        selectByMouse: true
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator { bottom: 0; top: 99999 }
                        onEditingFinished: panel.commitCoordinate(this, widgetSection.wid, "x")
                      }
                    }

                    Row {
                      width: 98
                      height: parent.height
                      spacing: 8

                      Text {
                        textFormat: Text.PlainText
                        text: "Y"
                        width: 12
                        color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                        font.family: Style.font.family
                        font.pixelSize: 10
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      TextField {
                        width: 78
                        height: 28
                        font.pixelSize: 11
                        verticalAlignment: TextInput.AlignVCenter
                        text: panel.coordinateText(widgetSection.wid, "y")
                        placeholderText: "Auto"
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                        selectByMouse: true
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator { bottom: 0; top: 99999 }
                        onEditingFinished: panel.commitCoordinate(this, widgetSection.wid, "y")
                      }
                    }


                    Button {
                      width: 78
                      height: 28
                      text: "Auto"
                      tooltipText: "Reset position to automatic"
                      fontSize: 11
                      horizontalPadding: 6
                      verticalPadding: 0
                      bordered: true
                      focusable: true
                      enabled: positionRow.hasManualPosition
                      opacity: enabled ? 1 : 0.35
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: panel.resetWidgetPosition(widgetSection.wid)
                    }
                  }
                }

                Text {
                  width: expandedSettings.rowWidth
                  visible: widgetSection.wid === "battery" || widgetSection.wid === "media"
                  text: "Updates automatically from " + (widgetSection.wid === "battery" ? "UPower" : "MPRIS")
                  color: panel.textColor
                  font.family: Style.font.family
                  font.pixelSize: 11
                  wrapMode: Text.WordWrap
                }

                // Refresh interval
                Row {
                  visible: widgetSection.wid !== "battery" && widgetSection.wid !== "media"
                  width: expandedSettings.rowWidth
                  spacing: 8
                  height: 28

                  Text {
                    textFormat: Text.PlainText
                    text: "Refresh"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: expandedSettings.labelWidth
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  PanelSlider {
                    width: parent.width - expandedSettings.labelWidth - 50 - 16
                    height: 28
                    value: Config.widgetRefreshInterval(panel.config, widgetSection.wid)
                    minimum: 500
                    maximum: 30000
                    step: 500
                    integer: true
                    onMoved: panel.widgetConfigChanged(widgetSection.wid, "refreshInterval", Math.round(value))
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: (Config.widgetRefreshInterval(panel.config, widgetSection.wid) / 1000).toFixed(1) + "s"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: 50
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                // Card width — available for ALL widgets
                Row {
                  width: expandedSettings.rowWidth
                  spacing: 8
                  height: 28

                  Text {
                    textFormat: Text.PlainText
                    text: "Card Width"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: expandedSettings.labelWidth
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  PanelSlider {
                    width: parent.width - expandedSettings.labelWidth - 60 - 16
                    height: 28
                    value: {
                      var w = panel.widgetNumber(widgetSection.wcfg, "cardWidth", 0)
                      return w > 0 ? w : 300
                    }
                    minimum: 200
                    maximum: 500
                    step: 10
                    integer: true
                    onMoved: panel.widgetConfigChanged(widgetSection.wid, "cardWidth", Math.round(value))
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: {
                      var w = panel.widgetNumber(widgetSection.wcfg, "cardWidth", 0)
                      return (w > 0 ? w : 300) + "px"
                    }
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: 60
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                // Card opacity — available for ALL widgets
                Row {
                  width: expandedSettings.rowWidth
                  spacing: 8
                  height: 28

                  Text {
                    textFormat: Text.PlainText
                    text: "Widget fade"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: expandedSettings.labelWidth
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  PanelSlider {
                    width: parent.width - expandedSettings.labelWidth - 50 - 16
                    height: 28
                    value: {
                      return panel.widgetNumber(widgetSection.wcfg, "cardOpacity", 1) * 100
                    }
                    minimum: 10
                    maximum: 100
                    step: 5
                    integer: true
                    onMoved: panel.widgetConfigChanged(widgetSection.wid, "cardOpacity", Math.round(value) / 100)
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: {
                      return Math.round(panel.widgetNumber(widgetSection.wcfg, "cardOpacity", 1) * 100) + "%"
                    }
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: 50
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                // Click-through toggle — available for ALL widgets
                CompactToggle {
                  width: expandedSettings.rowWidth
                  label: "Click-through (ignore all mouse input)"
                  checked: widgetSection.wcfg.clickThrough === true
                  onToggled: panel.widgetConfigChanged(widgetSection.wid, "clickThrough", value)
                }

                // Per-widget gauge size (for widgets that use gauges)
                Row {
                  width: expandedSettings.rowWidth
                  spacing: 8
                  height: 28
                  visible: widgetSection.wid === "systemMonitor"
                    || widgetSection.wid === "battery"
                    || widgetSection.wid === "networkSpeed"

                  Text {
                    textFormat: Text.PlainText
                    text: "Gauge Size"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: expandedSettings.labelWidth
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  PanelSlider {
                    width: parent.width - expandedSettings.labelWidth - 60 - 16
                    height: 28
                    value: panel.widgetNumber(widgetSection.wcfg, "gaugeDiameter", widgetSection.wid === "battery" ? 94 : 110)
                    minimum: 60
                    maximum: widgetSection.wid === "battery" ? 100 : 160
                    step: 5
                    integer: true
                    onMoved: panel.widgetConfigChanged(widgetSection.wid, "gaugeDiameter", Math.round(value))
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: panel.widgetNumber(widgetSection.wcfg, "gaugeDiameter", widgetSection.wid === "battery" ? 94 : 110) + "px"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: 60
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                // Per-widget gauge color mode (overrides global)
                Row {
                  width: expandedSettings.rowWidth
                  spacing: 8
                  height: 30
                  visible: widgetSection.wid === "systemMonitor"
                    || widgetSection.wid === "battery"
                    || widgetSection.wid === "networkSpeed"
                    || widgetSection.wid === "temperature"

                  Text {
                    textFormat: Text.PlainText
                    text: "Gauge Color"
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: 11
                    width: expandedSettings.labelWidth
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Segmented: Auto / Semantic / Theme
                  Row {
                    id: perGaugeOptions
                    height: 28
                    spacing: 3
                    anchors.verticalCenter: parent.verticalCenter

                    property string perMode: widgetSection.wcfg.gaugeColorMode || "auto"
                    function choose(mode) {
                      panel.widgetConfigChanged(widgetSection.wid, "gaugeColorMode", mode)
                    }
                    function move(mode) {
                      choose(mode)
                      if (mode === "auto") perGlobalOption.forceActiveFocus()
                      else if (mode === "semantic") perSemanticOption.forceActiveFocus()
                      else perThemeOption.forceActiveFocus()
                    }

                    Rectangle {
                      id: perGlobalOption
                      width: 56; height: 28; radius: 6
                      activeFocusOnTab: true
                      Accessible.role: Accessible.RadioButton
                      Accessible.name: "Use global gauge colors"
                      Accessible.checkable: true
                      Accessible.checked: perGaugeOptions.perMode === "auto"
                      Accessible.onPressAction: perGaugeOptions.choose("auto")
                      color: parent.perMode === "auto"
                        ? Qt.rgba(panel.accentColor.r, panel.accentColor.g, panel.accentColor.b, 0.2)
                        : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.04)
                      border.color: parent.perMode === "auto" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.06)
                      border.width: activeFocus ? 2 : 1
                      Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                          perGaugeOptions.move("semantic")
                        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                          perGaugeOptions.move("accent")
                        } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                          perGaugeOptions.choose("auto")
                        } else return
                        event.accepted = true
                      }
                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "Global"
                        color: parent.parent.perMode === "auto" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                        font.family: Style.font.family; font.pixelSize: 10; font.bold: parent.parent.perMode === "auto"
                      }
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          perGaugeOptions.choose("auto")
                          perGlobalOption.forceActiveFocus()
                        } }
                    }

                    Rectangle {
                      id: perSemanticOption
                      width: 70; height: 28; radius: 6
                      activeFocusOnTab: true
                      Accessible.role: Accessible.RadioButton
                      Accessible.name: "Use semantic gauge colors"
                      Accessible.checkable: true
                      Accessible.checked: perGaugeOptions.perMode === "semantic"
                      Accessible.onPressAction: perGaugeOptions.choose("semantic")
                      color: parent.perMode === "semantic"
                        ? Qt.rgba(panel.accentColor.r, panel.accentColor.g, panel.accentColor.b, 0.2)
                        : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.04)
                      border.color: parent.perMode === "semantic" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.06)
                      border.width: activeFocus ? 2 : 1
                      Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                          perGaugeOptions.move("accent")
                        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                          perGaugeOptions.move("auto")
                        } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                          perGaugeOptions.choose("semantic")
                        } else return
                        event.accepted = true
                      }
                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "Semantic"
                        color: parent.parent.perMode === "semantic" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                        font.family: Style.font.family; font.pixelSize: 10; font.bold: parent.parent.perMode === "semantic"
                      }
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          perGaugeOptions.choose("semantic")
                          perSemanticOption.forceActiveFocus()
                        } }
                    }

                    Rectangle {
                      id: perThemeOption
                      width: 60; height: 28; radius: 6
                      activeFocusOnTab: true
                      Accessible.role: Accessible.RadioButton
                      Accessible.name: "Use theme accent for gauge colors"
                      Accessible.checkable: true
                      Accessible.checked: perGaugeOptions.perMode === "accent"
                      Accessible.onPressAction: perGaugeOptions.choose("accent")
                      color: parent.perMode === "accent"
                        ? Qt.rgba(panel.accentColor.r, panel.accentColor.g, panel.accentColor.b, 0.2)
                        : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.04)
                      border.color: parent.perMode === "accent" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.06)
                      border.width: activeFocus ? 2 : 1
                      Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                          perGaugeOptions.move("auto")
                        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                          perGaugeOptions.move("semantic")
                        } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                          perGaugeOptions.choose("accent")
                        } else return
                        event.accepted = true
                      }
                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "Theme"
                        color: parent.parent.perMode === "accent" ? panel.accentColor : Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                        font.family: Style.font.family; font.pixelSize: 10; font.bold: parent.parent.perMode === "accent"
                      }
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          perGaugeOptions.choose("accent")
                          perThemeOption.forceActiveFocus()
                        } }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: {
                      var m = widgetSection.wcfg.gaugeColorMode || "auto"
                      if (m === "auto") return "Uses global setting"
                      if (m === "semantic") return "Green→Red"
                      return "Theme accent"
                    }
                    color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.58)
                    font.family: Style.font.family
                    font.pixelSize: 10
                    width: parent.width - expandedSettings.labelWidth - 200 - 16
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                // Widget-specific options (compact toggles)
                Column {
                  width: expandedSettings.rowWidth
                  spacing: 2
                  visible: widgetSection.wid === "systemMonitor"

                  CompactToggle {
                    label: "Show CPU gauge"
                    checked: widgetSection.wcfg.showCpu !== false
                    onToggled: panel.widgetConfigChanged(widgetSection.wid, "showCpu", value)
                  }
                  CompactToggle {
                    label: "Show RAM gauge"
                    checked: widgetSection.wcfg.showRam !== false
                    onToggled: panel.widgetConfigChanged(widgetSection.wid, "showRam", value)
                  }
                  CompactToggle {
                    label: "Show GPU gauge"
                    checked: widgetSection.wcfg.showGpu !== false
                    onToggled: panel.widgetConfigChanged(widgetSection.wid, "showGpu", value)
                  }
                }

                Column {
                  width: expandedSettings.rowWidth
                  spacing: 2
                  visible: widgetSection.wid === "battery"

                  CompactToggle {
                    label: "Show battery power (W)"
                    checked: widgetSection.wcfg.showPower !== false
                    onToggled: panel.widgetConfigChanged(widgetSection.wid, "showPower", value)
                  }
                  Text {
                    width: parent.width
                    text: "Power entering or leaving the battery, not charger or wall power."
                    color: panel.textColor
                    font.family: Style.font.family
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                  }
                  CompactToggle {
                    label: "Show power profiles"
                    checked: widgetSection.wcfg.showProfiles !== false
                    onToggled: panel.widgetConfigChanged(widgetSection.wid, "showProfiles", value)
                  }
                }

                Column {
                  width: expandedSettings.rowWidth
                  spacing: 2
                  visible: widgetSection.wid === "media"

                  CompactToggle {
                    label: "Show album art"
                    checked: widgetSection.wcfg.showAlbumArt !== false
                    onToggled: panel.widgetConfigChanged(widgetSection.wid, "showAlbumArt", value)
                  }
                  CompactToggle {
                    label: "Show playback controls"
                    checked: widgetSection.wcfg.showControls !== false
                    onToggled: panel.widgetConfigChanged(widgetSection.wid, "showControls", value)
                  }
                }

                // Top processes: process count + sort
                Column {
                  width: expandedSettings.rowWidth
                  spacing: 4
                  visible: widgetSection.wid === "topProcesses"

                  Row {
                    width: parent.width
                    spacing: 8
                    height: 28

                    Text {
                      textFormat: Text.PlainText
                      text: "Process count"
                      color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                      font.family: Style.font.family
                      font.pixelSize: 11
                      width: expandedSettings.labelWidth
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    PanelSlider {
                      width: parent.width - expandedSettings.labelWidth - 30 - 24
                      height: 28
                      value: panel.widgetNumber(widgetSection.wcfg, "processCount", 5)
                      minimum: 1
                      maximum: 15
                      step: 1
                      integer: true
                      onMoved: panel.widgetConfigChanged(widgetSection.wid, "processCount", Math.round(value))
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: panel.widgetNumber(widgetSection.wcfg, "processCount", 5)
                      width: 30
                      color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.65)
                      font.family: Style.font.family
                      font.pixelSize: 11
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: 8
                    height: 28

                    Text {
                      textFormat: Text.PlainText
                      text: "Sort by"
                      color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                      font.family: Style.font.family
                      font.pixelSize: 11
                      width: expandedSettings.labelWidth
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    WidgetDropdown {
                      width: 140
                      height: 28
                      value: widgetSection.wcfg.sortBy || "cpu"
                      hostActive: panel.visible && widgetSection.expanded
                      dismissRevision: panel.menuRevision
                      options: [
                        { value: "cpu", label: "CPU usage" },
                        { value: "mem", label: "Memory usage" }
                      ]
                      onChanged: function(value) { panel.widgetConfigChanged(widgetSection.wid, "sortBy", value) }
                    }
                  }
                }

                // Network speed: interface picker
                // Interfaces are discovered dynamically from /proc/net/dev
                Column {
                  width: expandedSettings.rowWidth
                  spacing: 4
                  visible: widgetSection.wid === "networkSpeed"

                  // Read /proc/net/dev once to discover available interfaces
                  FileView {
                    id: netDevDiscovery
                    path: "/proc/net/dev"
                    watchChanges: false
                    printErrors: false
                    onLoaded: {
                      var lines = String(text() || "").split("\n")
                      var opts = [{ value: "auto", label: "Auto-detect" }]
                      for (var i = 2; i < lines.length; i++) {
                        var line = lines[i].trim()
                        if (!line) continue
                        var match = line.match(/^(\S+):/)
                        if (!match) continue
                        var iface = match[1]
                        if (iface === "lo") continue
                        var label = iface
                        if (iface.indexOf("wl") === 0) label = iface + " (WiFi)"
                        else if (iface.indexOf("en") === 0) label = iface + " (Ethernet)"
                        opts.push({ value: iface, label: label })
                      }
                      ifaceDropdown.options = opts
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: 8
                    height: 28

                    Text {
                      textFormat: Text.PlainText
                      text: "Interface"
                      color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                      font.family: Style.font.family
                      font.pixelSize: 11
                      width: expandedSettings.labelWidth
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    WidgetDropdown {
                      id: ifaceDropdown
                      width: 160
                      height: 28
                      value: widgetSection.wcfg.interface || "auto"
                      hostActive: panel.visible && widgetSection.expanded
                      dismissRevision: panel.menuRevision
                      options: [{ value: "auto", label: "Auto-detect" }]
                      onChanged: function(value) { panel.widgetConfigChanged(widgetSection.wid, "interface", value) }
                    }
                  }
                }

                // Disk usage: info text
                Text {
                  textFormat: Text.PlainText
                  text: "Shows all real filesystems. Pseudo-filesystems are filtered automatically."
                  color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.58)
                  font.family: Style.font.family
                  font.pixelSize: 11
                  width: expandedSettings.rowWidth
                  wrapMode: Text.WordWrap
                  visible: widgetSection.wid === "diskUsage"
                }

                // Temperature: sensor toggles
                Column {
                  width: expandedSettings.rowWidth
                  spacing: 2
                  visible: widgetSection.wid === "temperature"

                  Row {
                    width: parent.width
                    height: 28
                    spacing: 8

                    Text {
                      textFormat: Text.PlainText
                      text: "Temperature unit"
                      color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.72)
                      font.family: Style.font.family
                      font.pixelSize: 11
                      width: expandedSettings.labelWidth
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    WidgetDropdown {
                      width: 160
                      height: 28
                      value: widgetSection.wcfg.unit === "fahrenheit" ? "fahrenheit" : "celsius"
                      hostActive: panel.visible && widgetSection.expanded
                      dismissRevision: panel.menuRevision
                      options: [
                        { value: "celsius", label: "Celsius (°C)" },
                        { value: "fahrenheit", label: "Fahrenheit (°F)" }
                      ]
                      onChanged: function(value) { panel.widgetConfigChanged(widgetSection.wid, "unit", value) }
                    }
                  }

                  CompactToggle {
                    label: "Show CPU temperature"
                    checked: widgetSection.wcfg.sensors
                      ? widgetSection.wcfg.sensors.indexOf("cpu") !== -1 : true
                    onToggled: {
                      var s = widgetSection.wcfg.sensors ? widgetSection.wcfg.sensors.slice() : ["cpu", "gpu"]
                      if (value) { if (s.indexOf("cpu") === -1) s.push("cpu") }
                      else { s = s.filter(function(x) { return x !== "cpu" }) }
                      panel.widgetConfigChanged(widgetSection.wid, "sensors", s)
                    }
                  }
                  CompactToggle {
                    label: "Show GPU temperature"
                    checked: widgetSection.wcfg.sensors
                      ? widgetSection.wcfg.sensors.indexOf("gpu") !== -1 : true
                    onToggled: {
                      var s = widgetSection.wcfg.sensors ? widgetSection.wcfg.sensors.slice() : ["cpu", "gpu"]
                      if (value) { if (s.indexOf("gpu") === -1) s.push("gpu") }
                      else { s = s.filter(function(x) { return x !== "gpu" }) }
                      panel.widgetConfigChanged(widgetSection.wid, "sensors", s)
                    }
                  }
                  CompactToggle {
                    label: "Show fan speed"
                    checked: widgetSection.wcfg.showFan !== false
                    onToggled: {
                      panel.widgetConfigChanged(widgetSection.wid, "showFan", value)
                    }
                  }
                }
              }

              Rectangle {
                width: parent.width
                height: 1
                color: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, 0.06)
                visible: widgetSection.index < Config.allWidgetIds().length - 1
              }
            }
          }

          // Reset button
          Button {
            text: panel.resetArmed ? "Confirm reset to defaults" : "Reset to defaults"
            iconText: "↺"
            focusable: true
            onClicked: {
              if (panel.resetArmed) {
                panel.resetRequested()
                panel.resetArmed = false
              } else panel.resetArmed = true
            }
            anchors.horizontalCenter: parent.horizontalCenter
          }

          bottomPadding: 20
        }
      }
    }
  }
}
