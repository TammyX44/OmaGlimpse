import QtQuick
import QtQuick.Shapes
import qs.Commons

// Circular ring gauge — reusable component for all widget gauges.
// Thin ring style matching macOS-style widget reference:
//   - Thin track ring (dim)
//   - Thin progress arc (accent or white)
//   - Large percentage text in center
//   - Small label below
//   - Optional sub-label with details
Item {
  id: gauge

  property real value: 0          // 0..100
  property string label: ""       // e.g. "CPU"
  property string subLabel: ""    // e.g. "Load 1.85"
  property string displayText: "" // overrides center text if non-empty
  property color accentColor: Color.accent
  property color trackColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.10)
  property color textColor: Color.foreground
  property color subTextColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.60)
  property real diameter: 100
  property real arcWidth: 4          // configurable stroke thickness
  property bool showTicks: false     // draw 4 tick marks at 0/25/50/75%
  property color glowColor: "transparent" // subtle glow behind progress arc
  property color labelColor: textColor    // override label color (e.g. semantic)
  property real labelSpacing: 8           // gap between gauge and label
  property bool animateValue: true

  readonly property real fraction: Math.max(0, Math.min(1, value / 100))
  readonly property real arcRadius: diameter / 2 - arcWidth - 2
  readonly property real startAngle: 270
  readonly property real sweepAngle: 360

  width: diameter
  height: diameter + labelSpacing + gaugeLabel.implicitHeight
    + (subLabel !== "" ? 4 + gaugeDetail.implicitHeight : 0)

  Behavior on value {
    enabled: gauge.animateValue
    NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
  }

  Shape {
    id: shape
    width: gauge.diameter
    height: gauge.diameter
    preferredRendererType: Shape.CurveRenderer
    anchors.horizontalCenter: parent.horizontalCenter

    // Track: full circle, dim
    ShapePath {
      strokeWidth: gauge.arcWidth
      strokeColor: gauge.trackColor
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: gauge.diameter / 2
        centerY: gauge.diameter / 2
        radiusX: gauge.arcRadius
        radiusY: gauge.arcRadius
        startAngle: gauge.startAngle
        sweepAngle: gauge.sweepAngle
      }
    }

    // Glow: wider, dimmer arc behind progress (only when glowColor has alpha)
    ShapePath {
      strokeWidth: gauge.glowColor.a > 0 ? gauge.arcWidth + 4 : 0
      strokeColor: gauge.glowColor
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: gauge.diameter / 2
        centerY: gauge.diameter / 2
        radiusX: gauge.arcRadius
        radiusY: gauge.arcRadius
        startAngle: gauge.startAngle
        sweepAngle: gauge.sweepAngle * gauge.fraction
      }
    }

    // Progress arc
    ShapePath {
      strokeWidth: gauge.arcWidth
      strokeColor: gauge.accentColor
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: gauge.diameter / 2
        centerY: gauge.diameter / 2
        radiusX: gauge.arcRadius
        radiusY: gauge.arcRadius
        startAngle: gauge.startAngle
        sweepAngle: gauge.sweepAngle * gauge.fraction
      }
    }

    // Tick marks at 0/25/50/75% positions (only when showTicks is true)
    ShapePath {
      strokeWidth: gauge.showTicks ? 1 : 0
      strokeColor: Qt.rgba(gauge.textColor.r, gauge.textColor.g, gauge.textColor.b, 0.25)
      fillColor: "transparent"

      // 4 tick marks at 0%, 25%, 50%, 75% (angles 270, 0, 90, 180)
      PathMove { x: gauge.diameter / 2 + gauge.arcRadius + 1; y: gauge.diameter / 2 }
      PathLine { x: gauge.diameter / 2 + gauge.arcRadius - gauge.arcWidth - 1; y: gauge.diameter / 2 }

      PathMove { x: gauge.diameter / 2; y: gauge.diameter / 2 + gauge.arcRadius + 1 }
      PathLine { x: gauge.diameter / 2; y: gauge.diameter / 2 + gauge.arcRadius - gauge.arcWidth - 1 }

      PathMove { x: gauge.diameter / 2 - gauge.arcRadius - 1; y: gauge.diameter / 2 }
      PathLine { x: gauge.diameter / 2 - gauge.arcRadius + gauge.arcWidth + 1; y: gauge.diameter / 2 }

      PathMove { x: gauge.diameter / 2; y: gauge.diameter / 2 - gauge.arcRadius - 1 }
      PathLine { x: gauge.diameter / 2; y: gauge.diameter / 2 - gauge.arcRadius + gauge.arcWidth + 1 }
    }
  }

  // Center percentage text — large, bold
  Text {
    anchors.centerIn: shape
    width: gauge.diameter * 0.78
    height: gauge.diameter * 0.34
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    fontSizeMode: Text.Fit
    textFormat: Text.PlainText
    text: gauge.displayText !== "" ? gauge.displayText : (Math.round(gauge.value) + "%")
    minimumPixelSize: 9
    color: gauge.textColor
    font.family: Style.font.family
    font.pixelSize: gauge.diameter * 0.24
    font.bold: true
  }

  // Label below the gauge — small, bold, letter-spaced
  Text {
    id: gaugeLabel
    width: gauge.width
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
    anchors.top: shape.bottom
    anchors.topMargin: gauge.labelSpacing
    anchors.horizontalCenter: shape.horizontalCenter
    textFormat: Text.PlainText
    text: gauge.label
    color: gauge.labelColor
    font.family: Style.font.family
    font.pixelSize: 10
    font.weight: Font.Medium
    font.letterSpacing: 1.5
  }

  // Sub-label (optional details) — very small, muted but readable
  Text {
    id: gaugeDetail
    width: gauge.width
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
    fontSizeMode: Text.Fit
    minimumPixelSize: 7
    maximumLineCount: 1
    visible: gauge.subLabel !== ""
    anchors.top: gaugeLabel.bottom
    anchors.topMargin: 4
    anchors.horizontalCenter: shape.horizontalCenter
    textFormat: Text.PlainText
    text: gauge.subLabel
    color: gauge.subTextColor
    font.family: Style.font.family
    font.pixelSize: 10
  }
}
