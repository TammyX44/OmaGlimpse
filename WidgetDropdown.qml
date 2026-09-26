import QtQuick
import QtQuick.Controls
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Ui

// Local counterpart to Ui/Dropdown. The popup is explicitly parented and
// positioned in window-content coordinates so it also works in layer-shell
// overlay windows, where a Popup's visual parent is not the trigger item.
Item {
  id: root

  property string label: ""
  property string value: ""
  property var options: []
  property bool hostActive: true
  property int dismissRevision: 0

  property color foreground: Color.popups.text
  property color background: Color.popups.background
  property color popupBorder: Color.popups.border
  property color accent: Color.accent
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Color.popups.border, Style.normalBorderWidth)
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  property bool showLabel: true
  property bool hasCursor: false

  readonly property bool popupOpen: popup.opened

  function open() {
    // A layer-shell panel can recreate its overlay when hidden and shown.
    // Reparent to the current overlay so this menu still opens afterward.
    popup.parent = Overlay.overlay
    popup.reposition()
    popup.open()
  }

  function close() {
    popup.close()
  }

  function toggle() {
    popup.opened ? close() : open()
  }

  signal changed(string value)
  signal hovered(bool isHovered)

  function optionValue(option) {
    return (option && typeof option === "object") ? String(option.value) : String(option)
  }

  function optionLabel(option) {
    return (option && typeof option === "object") ? String(option.label) : String(option)
  }

  function currentLabel() {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === value)
        return optionLabel(options[i])
    }
    return value
  }

  implicitWidth: Style.spacing.dropdownWidth
  onVisibleChanged: if (!visible && popup.opened) close()
  onHostActiveChanged: if (!hostActive && popup.opened) close()
  onDismissRevisionChanged: if (popup.opened) close()
  implicitHeight: showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight

  Column {
    anchors.fill: parent
    spacing: Style.spacing.labelGap

    Text {
      textFormat: Text.PlainText
      visible: root.showLabel && root.label !== ""
      text: root.label
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    BorderSurface {
      id: trigger

      width: parent.width
      height: root.rowHeight
      radius: Style.cornerRadius

      readonly property bool _focused: trigger.activeFocus
      readonly property bool _hot: triggerHover.hovered || root.hasCursor
      readonly property var _borderSpec: Border.controlSpec(trigger._focused ? "focus" : (trigger._hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

      color: Style.controlFill(trigger._focused, trigger._hot, root.foreground, root.accent)
      Accessible.role: Accessible.ComboBox
      Accessible.name: root.label !== "" ? root.label : root.currentLabel()
      borderSpec: _borderSpec
      activeFocusOnTab: true

      HoverHandler {
        id: triggerHover
        onHoveredChanged: root.hovered(hovered)
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
          root.toggle()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape && popup.opened) {
          root.close()
          event.accepted = true
        }
      }

      Text {
        anchors.left: parent.left
        anchors.right: chevron.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
        anchors.rightMargin: trigger.borderRight + Style.spacing.md
        textFormat: Text.PlainText
        text: root.currentLabel()
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        id: chevron

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
        text: "󰅀"
        color: Qt.darker(root.foreground, 1.2)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          trigger.forceActiveFocus()
          root.toggle()
        }
      }

      Popup {
        id: popup

        // Qt Quick Controls positions Popup content in the window overlay.
        // Using that host keeps x/y and hit-testing in one coordinate space.
        parent: Overlay.overlay

        property real _anchorX: 0
        property real _anchorY: 0
        readonly property real _edgeMargin: Style.spacing.md
        readonly property real _gap: Style.spacing.xxs
        readonly property var _anchorContentItem: Overlay.overlay
        readonly property real _windowWidth: parent ? parent.width : 0
        readonly property real _windowHeight: parent ? parent.height : 0
        readonly property real _horizontalMargin: Math.min(_edgeMargin, _windowWidth / 2)
        readonly property real _verticalMargin: Math.min(_edgeMargin, _windowHeight / 2)
        readonly property real _idealHeight: Math.min(
          root.options.length * root.popupRowHeight
            + Math.max(0, root.options.length - 1) * Style.spacing.labelGap
            + Style.spacing.xxs,
          root.popupRowHeight * 8 + 7 * Style.spacing.labelGap + Style.spacing.xxs)
        readonly property real _availableBelow: Math.max(0,
          _windowHeight - _verticalMargin - (_anchorY + trigger.height + _gap))
        readonly property real _availableAbove: Math.max(0,
          _anchorY - _gap - _verticalMargin)
        readonly property bool _opensAbove: _idealHeight > _availableBelow
          && _availableAbove > _availableBelow
        readonly property real _resolvedHeight: Math.min(_idealHeight,
          _opensAbove ? _availableAbove : _availableBelow)
        readonly property real _resolvedWidth: Math.max(0,
          Math.min(trigger.width, _windowWidth - 2 * _horizontalMargin))

        function reposition() {
          if (!parent || !_anchorContentItem || !_anchorContentItem.mapFromItem)
            return

          // mapFromItem already includes the Flickable content item's offset.
          // Subtracting contentY again detaches the menu from a scrolled trigger.
          var point = _anchorContentItem.mapFromItem(trigger, 0, 0)
          if (Math.abs(_anchorX - point.x) > 0.25)
            _anchorX = point.x
          if (Math.abs(_anchorY - point.y) > 0.25)
            _anchorY = point.y
        }

        x: Math.max(_horizontalMargin,
          Math.min(_anchorX, _windowWidth - _horizontalMargin - width))
        y: Math.max(_verticalMargin,
          Math.min(_opensAbove
              ? _anchorY - _gap - height
              : _anchorY + trigger.height + _gap,
            _windowHeight - _verticalMargin - height))
        width: _resolvedWidth
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        implicitHeight: _resolvedHeight
        padding: Style.spacing.hairline
        leftPadding: Border.left(root.popupBorderSpec) + Style.spacing.hairline
        rightPadding: Border.right(root.popupBorderSpec) + Style.spacing.hairline
        topPadding: Border.top(root.popupBorderSpec) + Style.spacing.hairline
        bottomPadding: Border.bottom(root.popupBorderSpec) + Style.spacing.hairline
        focus: true

        // Ancestor movement (notably Flickable scrolling) does not emit an
        // x/y change on the trigger itself. Track it only while the popup is
        // visible so mouse hit-testing and the visual anchor stay aligned.
        Timer {
          interval: 33
          running: popup.opened
          repeat: true
          onTriggered: popup.reposition()
        }

        Connections {
          target: trigger
          function onXChanged() { popup.reposition() }
          function onYChanged() { popup.reposition() }
          function onWidthChanged() { popup.reposition() }
          function onHeightChanged() { popup.reposition() }
        }

        background: BorderSurface {
          color: root.background
          borderSpec: root.popupBorderSpec
          radius: Style.cornerRadius
        }

        onAboutToShow: reposition()
        onOpened: {
          reposition()
          optionList.currentIndex = optionList.count > 0
            ? Math.max(0, optionList.indexOfValue(root.value))
            : -1
          optionList.forceActiveFocus()
        }

        onClosed: trigger.forceActiveFocus()

        contentItem: ListView {
          id: optionList

          spacing: Style.spacing.labelGap
          implicitHeight: contentHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.options
          currentIndex: -1

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Down || event.text === "j") {
              if (optionList.count > 0)
                optionList.currentIndex = Math.min(optionList.count - 1, optionList.currentIndex + 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up || event.text === "k") {
              if (optionList.count > 0)
                optionList.currentIndex = Math.max(0, optionList.currentIndex - 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                       || event.key === Qt.Key_Space) {
              optionList.selectCurrent()
              event.accepted = true
            }
          }

          function indexOfValue(selectedValue) {
            for (var i = 0; i < root.options.length; i++) {
              if (root.optionValue(root.options[i]) === selectedValue)
                return i
            }
            return -1
          }

          function selectCurrent() {
            if (currentIndex < 0 || currentIndex >= root.options.length)
              return

            var selectedValue = root.optionValue(root.options[currentIndex])
            root.changed(selectedValue)
            root.close()
          }

          delegate: Rectangle {
            required property var modelData
            required property int index

            width: optionList.width
            height: root.popupRowHeight
            color: index === optionList.currentIndex
              ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
              : "transparent"

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.rightMargin: Style.spacing.controlPaddingX
              textFormat: Text.PlainText
              text: root.optionLabel(modelData)
              color: index === optionList.currentIndex
                ? root.accent
                : root.foreground
              font.family: root.fontFamily
              font.bold: index === optionList.currentIndex
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: optionList.currentIndex = parent.index
              onPositionChanged: optionList.currentIndex = parent.index
              onClicked: optionList.selectCurrent()
            }
          }
        }
      }
    }
  }
}
