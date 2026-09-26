import QtQuick
import Quickshell
import Quickshell.Io

// Run with: QT_QPA_PLATFORM=offscreen quickshell -p tests/artwork-process-smoke.qml
ShellRoot {
  id: root
  property bool gotStdout: false
  property bool gotExit: false
  property string result: ""

  function finish() {
    if (!gotStdout || !gotExit) return
    if (result === "artwork-ready") console.log("ARTWORK_PROCESS_SMOKE_OK")
    else console.error("ARTWORK_PROCESS_SMOKE_FAILED: " + result)
    Qt.quit()
  }

  Process {
    id: artworkFetch
    command: ["printf", "artwork-ready"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.result = String(text)
        root.gotStdout = true
        root.finish()
      }
    }
    onExited: function(code) {
      if (code !== 0) root.result = "exit " + code
      root.gotExit = true
      root.finish()
    }
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: {
      console.error("ARTWORK_PROCESS_SMOKE_TIMEOUT")
      Qt.quit()
    }
  }
}
