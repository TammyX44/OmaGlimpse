import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Compact inline toggle: label on left, small switch on right.
// 28px tall — much smaller than the 54px Omarchy Toggle.
// Stateless: emits toggled(!checked) on click. Caller updates the model.
Item {
  id: root

  property string label: ""
  property bool checked: false
  property color textColor: Color.foreground
  property color accentColor: Color.accent

  signal toggled(bool value)

  width: parent ? parent.width : 200
  height: 28

  activeFocusOnTab: true
  Accessible.role: Accessible.CheckBox
  Accessible.name: root.label
  Accessible.checked: root.checked

  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: root.toggled(!root.checked)
  }

  HoverHandler {
    cursorShape: Qt.PointingHandCursor
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.toggled(!root.checked)
      event.accepted = true
    }
  }
  Accessible.onPressAction: root.toggled(!root.checked)

  Rectangle {
    anchors.fill: parent
    radius: 5
    color: "transparent"
    border.width: root.activeFocus ? 1 : 0
    border.color: root.accentColor
    z: 2
  }
  Row {
    id: contentRow
    anchors.fill: parent
    spacing: 8

    Text {
    textFormat: Text.PlainText
    text: root.label
    color: root.textColor
    font.family: Style.font.family
    font.pixelSize: 12
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width - track.width - parent.spacing
    elide: Text.ElideRight
  }

  Rectangle {
    id: track
    width: 32
    height: 18
    radius: 9
    color: root.checked
      ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.8)
      : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.15)
    border.color: root.checked ? root.accentColor : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.2)
    border.width: 1
    anchors.verticalCenter: parent.verticalCenter

    Rectangle {
      width: 12
      height: 12
      radius: 6
      color: root.textColor
      anchors.verticalCenter: parent.verticalCenter
      x: root.checked ? parent.width - 14 : 2
      Behavior on x { NumberAnimation { duration: 100 } }
    }

  }
}
  }
