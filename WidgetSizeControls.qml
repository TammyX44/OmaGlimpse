import QtQuick
import qs.Commons
import qs.Ui

// Matched dimension rows with independent Auto resets and content-safe height.
Column {
  id: root
  property string widgetId: ""
  property var widgetCfg: ({})
  property real labelWidth: 100
  property real minimumHeight: 80
  property real actualHeight: 0
  property color textColor: Color.foreground
  property color accentColor: Color.accent
  signal dimensionChanged(string key, real value)
  spacing: 4

  Repeater {
    model: ["cardWidth", "cardHeight"]
    Row {
      id: dimensionRow
      required property string modelData
      readonly property bool isHeight: modelData === "cardHeight"
      readonly property real requested: Number(root.widgetCfg[modelData]) || 0
      readonly property real contentMinimum: Math.min(1000, Math.max(80, Math.ceil(root.minimumHeight / 10) * 10))
      width: root.width
      height: 28
      spacing: 8

      Text {
        textFormat: Text.PlainText
        text: dimensionRow.isHeight ? "Card Height" : "Card Width"
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.72)
        font.family: Style.font.family
        font.pixelSize: 11
        width: root.labelWidth
        anchors.verticalCenter: parent.verticalCenter
      }
      PanelSlider {
        objectName: root.widgetId + (dimensionRow.isHeight ? "HeightSlider" : "WidthSlider")
        width: Math.max(0, parent.width - root.labelWidth - 64 - 42 - 24)
        height: 28
        minimum: dimensionRow.isHeight ? dimensionRow.contentMinimum : 200
        maximum: dimensionRow.isHeight ? 1000 : 500
        step: 10
        integer: true
        value: Math.max(minimum, Math.min(maximum, dimensionRow.requested > 0 ? dimensionRow.requested
          : (dimensionRow.isHeight ? root.actualHeight || minimum : 300)))
        trackColor: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.15)
        fillColor: root.accentColor
        knobColor: root.textColor
        Accessible.role: Accessible.Slider
        Accessible.name: (dimensionRow.isHeight ? "Card height for " : "Card width for ") + root.widgetId
        activeFocusOnTab: true
        Keys.onLeftPressed: root.dimensionChanged(dimensionRow.modelData, Math.max(minimum, Math.min(maximum, value - step)))
        Keys.onRightPressed: root.dimensionChanged(dimensionRow.modelData, Math.max(minimum, Math.min(maximum, value + step)))
        onMoved: function(value) {
          root.dimensionChanged(dimensionRow.modelData, Math.round(Math.max(minimum, Math.min(maximum, value))))
        }
        Rectangle {
          objectName: root.widgetId + (dimensionRow.isHeight ? "HeightFocus" : "WidthFocus")
          anchors.fill: parent
          radius: 4
          color: "transparent"
          border.width: 1
          border.color: root.accentColor
          visible: parent.activeFocus
        }
      }
      Text {
        objectName: root.widgetId + (dimensionRow.isHeight ? "HeightValue" : "WidthValue")
        textFormat: Text.PlainText
        text: dimensionRow.requested > 0
          ? Math.round(dimensionRow.isHeight ? Math.max(dimensionRow.requested, root.minimumHeight) : dimensionRow.requested) + "px" : "Auto"
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.65)
        font.family: Style.font.family
        font.pixelSize: 11
        width: 64
        anchors.verticalCenter: parent.verticalCenter
      }
      Rectangle {
        objectName: root.widgetId + (dimensionRow.isHeight ? "HeightAuto" : "WidthAuto")
        width: 42; height: 26; radius: 6
        anchors.verticalCenter: parent.verticalCenter
        enabled: dimensionRow.requested > 0
        opacity: enabled ? 1 : 0.4
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.06)
        border.width: activeFocus ? 1 : 0
        border.color: root.accentColor
        activeFocusOnTab: enabled
        Accessible.role: Accessible.Button
        Accessible.name: (dimensionRow.isHeight ? "Reset card height to Auto for " : "Reset card width to Auto for ") + root.widgetId
        signal clicked()
        onClicked: root.dimensionChanged(dimensionRow.modelData, 0)
        Keys.onReturnPressed: clicked()
        Keys.onSpacePressed: clicked()
        Text {
          anchors.centerIn: parent
          text: "Auto"
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: 11
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: parent.clicked()
        }
      }
    }
  }
  Text {
    width: root.width
    text: "Height expands to fit content. Auto keeps the natural size."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.72)
    font.family: Style.font.family
    font.pixelSize: 11
  }
}
