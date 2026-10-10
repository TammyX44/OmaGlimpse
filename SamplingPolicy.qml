import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "SamplingModel.js" as Sampling

// Instantiate once in Widgets. Empty screenName means any powered output.
// There is no global lock observer / DPMS notify API in installed Quickshell.
Scope {
  id: root

  property bool monitoringEnabled: true
  property bool enabled: true
  property string screenName: ""
  property real powerSaverMultiplier: 3
  readonly property bool powerSaver: PowerProfiles.profile === PowerProfile.PowerSaver
  readonly property bool samplingEnabled: root.enabled && !root.locked && root.displayOn
  readonly property real samplingMultiplier: root.powerSaver
    ? (isFinite(root.powerSaverMultiplier) ? Math.max(1, root.powerSaverMultiplier) : 1) : 1

  // Last-good observations survive transient IPC failures. Before a first
  // successful query, sampling stays on. Errors expose that uncertainty.
  property bool locked: false
  property bool displayOn: true
  property string lockMonitorError: "Lock state not yet observed"
  property string displayMonitorError: "Display state not yet observed"
  readonly property int fallbackInterval: 2000

  function observeLock(raw) {
    var state = Sampling.lockState(raw)
    root.lockMonitorError = state === null ? "Lock IPC unavailable or invalid" : ""
    if (state !== null) root.locked = state
  }
  function observeDisplays(raw) {
    var state = Sampling.displayState(raw, root.screenName)
    root.displayMonitorError = state === null ? "Display IPC unavailable or invalid" : ""
    if (state !== null) root.displayOn = state
  }
  function refresh() {
    if (!root.monitoringEnabled) return
    if (!lockProc.running) lockProc.running = true
    if (!displayProc.running) displayProc.running = true
  }
  onScreenNameChanged: root.refresh()
  onMonitoringEnabledChanged: {
    if (root.monitoringEnabled) root.refresh()
    else { lockProc.running = false; displayProc.running = false }
  }
  Component.onCompleted: root.refresh()

  Process {
    id: lockProc
    command: ["timeout", "--kill-after=0.25s", "1s", "omarchy-shell", "lock", "isLocked"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.monitoringEnabled) root.observeLock(text)
    }
    onExited: function(code) {
      if (root.monitoringEnabled && code !== 0) root.lockMonitorError = "Lock IPC failed or timed out"
    }
  }
  Process {
    id: displayProc
    command: ["timeout", "--kill-after=0.25s", "1s", "hyprctl", "-j", "monitors", "all"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.monitoringEnabled) root.observeDisplays(text)
    }
    onExited: function(code) {
      if (root.monitoringEnabled && code !== 0) root.displayMonitorError = "Display IPC failed or timed out"
    }
  }
  Timer {
    interval: root.fallbackInterval
    running: root.monitoringEnabled
    repeat: true
    onTriggered: root.refresh()
  }
}
