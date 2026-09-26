import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget: gear icon that opens the desktop widgets settings panel.
// Uses BarIconButton for consistent Omarchy bar styling.
BarWidget {
  id: root
  moduleName: "io.github.tammyx44.omawidgets"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: ipcCall
    command: ["qs", "ipc", "--path", "/usr/share/omarchy/shell", "call", "io.github.tammyx44.omawidgets", "openSettings"]
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0e4"
    tooltipText: "Widget Settings"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) return
      ipcCall.running = false
      ipcCall.running = true
    }
  }
}
