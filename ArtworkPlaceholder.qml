import QtQuick

// Compact fallback for missing or unavailable album artwork.
// Pass the widget's resolved theme colors so light and dark palettes stay in sync.
Rectangle {
  id: root

  property color accentColor: "#cba6f7"
  property color textColor: "#cdd6f4"

  implicitWidth: 64
  implicitHeight: 64
  radius: 12
  color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.06)
  clip: true

  // A quiet record mark stays recognizable at the widget's 64px art size.
  Rectangle {
    width: 40
    height: 40
    anchors.centerIn: parent
    radius: width / 2
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.035)
    border.width: 1
    border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.48)
  }

  Rectangle {
    width: 28
    height: 28
    anchors.centerIn: parent
    radius: width / 2
    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.16)
  }

  Rectangle {
    width: 5
    height: 5
    anchors.centerIn: parent
    radius: width / 2
    color: root.accentColor
  }

  // Small offset wave marks give the record a media cue without adding text.
  Row {
    spacing: 2
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: 12
    anchors.bottomMargin: 12
    height: 10
    opacity: 0.82

    Repeater {
      model: [4, 8, 5]

      Rectangle {
        required property int modelData
        width: 2
        height: modelData
        radius: 1
        anchors.verticalCenter: parent.verticalCenter
        color: root.textColor
        opacity: 0.65
      }
    }
  }
}
