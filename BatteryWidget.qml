import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "WidgetConfig.js" as Config
import "WidgetTheme.js" as Theme
import "WidgetModel.js" as Model
import "SamplingModel.js" as Sampling
import "WidgetSizing.js" as Sizing

// Battery & power card: circular charge gauge, status text, and
// power profile picker. Config-driven colors and refresh interval.
BorderSurface {
  id: root

  // --- Properties set by Widgets.qml ---
  property string widgetId: "battery"
  property var config: ({})
  property color cardColor: Qt.rgba(0.09, 0.09, 0.10, 0.95)
  property color borderColor: Qt.rgba(1, 1, 1, 0.12)
  property color textColor: Color.foreground
  property color accentColor: Color.accent
  property real cardRadius: 18
  property real gaugeDiameter: 120
  property bool samplingEnabled: true
  property real samplingMultiplier: 1
  readonly property bool samplingActive: root.samplingEnabled && root.visible

  // --- Config-driven settings ---
  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property int refreshInterval: Config.widgetRefreshInterval(root.config, root.widgetId)
  readonly property bool showProfiles: root.widgetCfg.showProfiles !== false
  readonly property bool showPower: root.widgetCfg.showPower !== false
  readonly property real widgetGaugeDiameter: Number(root.widgetCfg.gaugeDiameter) || root.gaugeDiameter
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0
  readonly property real requestedHeight: Sizing.requestedHeight(root.widgetCfg.cardHeight)
  readonly property bool compactLayout: root.requestedHeight > 0 && root.requestedHeight < 200
  readonly property real minimumCardHeight: 80
  readonly property bool profilesVisible: root.showProfiles && root.profiles.length > 0
  readonly property real effectiveGaugeDiameter: root.requestedHeight > 0
    ? Math.max(root.compactLayout ? 34 : 60, Math.min(root.widgetGaugeDiameter, root.width - 32,
      root.requestedHeight - (root.compactLayout ? 16 + (root.profilesVisible ? 30 : 0)
        : 32 + 5 + batteryFont.height + 16 + (root.profilesVisible ? 46 : 10) + (root.profileError ? batteryFont.height + 10 : 0))))
    : Math.max(60, Math.min(root.widgetGaugeDiameter, root.width - 32))

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: 16

  width: widgetCardWidth > 0 ? widgetCardWidth : Math.max(260, root.widgetGaugeDiameter + 48)
  readonly property real naturalCardHeight: content.implicitHeight + 32
  height: Sizing.cardHeight(root.widgetCfg.cardHeight, root.naturalCardHeight, root.minimumCardHeight)
  FontMetrics { id: batteryFont; font.family: Style.font.family; font.pixelSize: 10 }


  readonly property var batteryDevice: UPower.displayDevice
  readonly property bool batteryPresent: !!(batteryDevice && batteryDevice.isPresent)
  readonly property bool onBattery: UPower.onBattery
  readonly property real batteryFraction: {
    // Quickshell's UPowerDevice.percentage is already a 0..1 fraction.
    // UPower's command-line output formats the same value as 0..100%, which
    // is why this must not be divided by 100 again here.
    var fraction = batteryPresent ? Number(batteryDevice.percentage) : 0
    return isFinite(fraction) ? Math.max(0, Math.min(1, fraction)) : 0
  }
  readonly property bool charging: batteryPresent && batteryDevice.state === UPowerDeviceState.Charging
  readonly property bool fullyCharged: batteryPresent && batteryDevice.state === UPowerDeviceState.FullyCharged
  readonly property string batteryState: {
    if (!batteryDevice) return "unknown"
    switch (batteryDevice.state) {
      case UPowerDeviceState.Charging: return "charging"
      case UPowerDeviceState.Discharging: return "discharging"
      case UPowerDeviceState.FullyCharged: return "charged"
      case UPowerDeviceState.Empty: return "empty"
      case UPowerDeviceState.PendingCharge: return "pending-charge"
      case UPowerDeviceState.PendingDischarge: return "pending-discharge"
      default: return "unknown"
    }
  }
  readonly property var batteryInfo: Model.batteryPresentation({
    ready: !!(batteryDevice && batteryDevice.ready), present: batteryPresent,
    state: batteryState, rate: batteryDevice ? batteryDevice.changeRate : null
  })

  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property string pendingProfile: ""
  property string inFlightProfile: ""
  property string profileError: ""
  property bool activeRefreshQueued: false
  property int confirmationReadSerial: 0
  readonly property string displayedProfile: root.pendingProfile || root.activeProfile

  // Linux platform_profile exposes a wider set of firmware names than
  // power-profiles-daemon's three public profiles. Normalize only for
  // comparison so keyboard/firmware changes still highlight the right pill.
  function normalizeProfileName(profile) {
    var name = String(profile || "").trim().toLowerCase()
    if (name === "low-power" || name === "cool" || name === "quiet") return "power-saver"
    if (name === "balanced-performance") return "balanced"
    if (name === "max-power") return "performance"
    return name
  }

  function profileMatches(candidate, active) {
    return root.normalizeProfileName(candidate) === root.normalizeProfileName(active)
  }

  function profileLabel(profile) {
    var normalized = root.normalizeProfileName(profile)
    if (normalized === "power-saver") return "Saver"
    if (normalized === "balanced") return "Balanced"
    if (normalized === "performance") return "Perf"

    var name = String(profile || "")
    return name.charAt(0).toUpperCase() + name.slice(1)
  }

  function nativeProfileName() {
    return Sampling.profileName(PowerProfiles.profile, PowerProfile.PowerSaver,
      PowerProfile.Balanced, PowerProfile.Performance)
  }

  function refreshActiveProfile() {
    // An explicit user action still needs confirmation if sampling is paused.
    if ((!root.samplingActive || !root.showProfiles) && !root.pendingProfile) return
    if (activeProfileProc.running) root.activeRefreshQueued = true
    else {
      activeProfileProc.readSerial += 1
      activeProfileProc.running = true
    }
  }

  // Native DBus notifications update the pill immediately; sysfs confirms
  // hardware state and catches firmware hotkeys that bypass the daemon.
  function refreshProfiles() {
    if (!root.showProfiles || !root.samplingActive) return
    if (!profilesProc.running) profilesProc.running = true
    root.refreshActiveProfile()
  }

  Connections {
    target: PowerProfiles
    function onProfileChanged() {
      root.activeProfile = root.nativeProfileName()
      root.refreshActiveProfile()
    }
    function onHasPerformanceProfileChanged() { root.refreshProfiles() }
  }

  // Parse the profile list (names only, no active state)
  function updateProfileList(raw) {
    var lines = String(raw || "").split("\n")
    var list = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      list.push(line)
    }
    if (list.length > 0) {
      profiles = list
      for (var j = 0; j < list.length; j++) {
        if (root.profileMatches(list[j], activeProfile)) {
          profileIndex = j
          break
        }
      }
    }
  }

  // Parse the raw sysfs active profile — this is the source of truth.
  // powerprofilesctl may disagree with this when the profile was changed
  // by a physical hotkey or other firmware-level action.
  function updateActiveProfile(raw, readSerial) {
    if (!root.samplingActive && !root.pendingProfile) return
    var profile = String(raw || "").trim()
    if (profile) {
      activeProfile = profile
      if (root.pendingProfile && profileConfirmTimer.running && !actionProc.running
          && readSerial >= root.confirmationReadSerial
          && root.profileMatches(root.pendingProfile, profile)) {
        root.pendingProfile = ""
        profileConfirmTimer.stop()
      }
      for (var i = 0; i < profiles.length; i++) {
        if (root.profileMatches(profiles[i], profile)) {
          profileIndex = i
          break
        }
      }
    }
  }

  function setProfile(profile) {
    if (!profile) return
    var selected = ""
    for (var i = 0; i < root.profiles.length; i++) {
      if (String(root.profiles[i]) === String(profile)) {
        selected = String(root.profiles[i])
        break
      }
    }
    if (!selected) {
      root.profileError = "Unsupported power profile"
      return
    }
    root.profileError = ""
    root.pendingProfile = selected
    if (!actionProc.running) root.startProfileAction(selected)
  }

  function startProfileAction(profile) {
    root.inFlightProfile = profile
    profileConfirmTimer.stop()
    actionProc.command = ["/usr/share/omarchy/bin/omarchy-powerprofiles-set",
      root.onBattery ? "battery" : "ac", profile]
    actionProc.running = true
  }

  readonly property string statusText: root.batteryInfo.status
  readonly property string compactSummary: root.statusText
    + (root.showPower && root.batteryInfo.available && root.batteryInfo.power
      ? " · " + root.batteryInfo.power : "")
  onShowProfilesChanged: if (showProfiles) Qt.callLater(root.refreshProfiles)
  onSamplingActiveChanged: if (root.samplingActive) Qt.callLater(root.refreshProfiles)

  // Profile list — load once at startup (rarely changes).
  // Uses omarchy-powerprofiles-list if available, falls back to powerprofilesctl.
  Process {
    id: profilesProc
    command: ["timeout", "--kill-after=1s", "3s", "sh", "-c", "omarchy-powerprofiles-list 2>/dev/null || powerprofilesctl list 2>/dev/null | awk '/^\\s*[* ]\\s*[a-zA-Z0-9-]+:$/{gsub(/^[*[:space:]]+|:$/,\"\"); print}' | tac"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfileList(text) }
  }

  // Active profile — read from sysfs (hardware truth) with powerprofilesctl fallback.
  // The sysfs file reflects the REAL hardware state including changes from
  // physical hotkeys (e.g. Lenovo G key, Fn+Q, etc.) that bypass power-profiles-daemon.
  // On systems without the ACPI platform profile driver, fall back to powerprofilesctl.
  Process {
    id: activeProfileProc
    objectName: "hardwareProfileProcess"
    property int readSerial: 0
    command: ["timeout", "--kill-after=1s", "2s", "sh", "-c", "cat /sys/firmware/acpi/platform_profile 2>/dev/null || powerprofilesctl get 2>/dev/null || echo ''"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateActiveProfile(text, activeProfileProc.readSerial) }
    onExited: {
      if (!root.activeRefreshQueued) return
      root.activeRefreshQueued = false
      Qt.callLater(root.refreshActiveProfile)
    }
  }

  // Slow hardware fallback for changes that emit no DBus notification.
  Timer {
    objectName: "hardwareProfileTimer"
    interval: Sampling.interval(10000, root.samplingMultiplier)
    repeat: true
    running: root.samplingActive && root.showProfiles
    onTriggered: root.refreshActiveProfile()
  }

  Timer {
    id: profileConfirmTimer
    objectName: "profileConfirmationTimer"
    interval: 3000
    repeat: false
    onTriggered: {
      if (!root.pendingProfile) return
      root.pendingProfile = ""
      root.profileError = "Profile change not confirmed by hardware"
      root.refreshProfiles()
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
      var completed = root.inFlightProfile
      root.inFlightProfile = ""
      if (root.pendingProfile && !root.profileMatches(root.pendingProfile, completed)) {
        root.startProfileAction(root.pendingProfile)
        return
      }
      if (exitCode !== 0) {
        root.pendingProfile = ""
        root.profileError = "Could not change power profile"
      } else {
        // Never confirm using a pre-action reading or just the DBus signal.
        root.confirmationReadSerial = activeProfileProc.readSerial + 1
        profileConfirmTimer.restart()
      }
      root.refreshProfiles()
      root.refreshActiveProfile()
    }
  }

  Component.onCompleted: {
    root.activeProfile = root.nativeProfileName()
    root.refreshProfiles()
  }

  // Always visible — the card container handles visibility.
  // If no battery is present, the status text shows "No battery".
  visible: true

  Column {
    id: content
    objectName: "widgetSizingContent"
    width: root.width - (root.compactLayout ? 16 : 24)
    anchors.centerIn: parent
    spacing: root.compactLayout ? 4 : 10

    Item {
      width: parent.width
      height: root.compactLayout ? Math.max(batteryGauge.height, batterySummary.height)
        : batteryGauge.height + 10 + batterySummary.height

      CircularGauge {
        id: batteryGauge
        x: root.compactLayout ? 0 : (parent.width - width) / 2
        value: root.batteryFraction * 100
        label: "BATTERY"
        showLabel: !root.compactLayout
        labelSpacing: 5
        arcWidth: 3
        displayText: root.batteryInfo.available ? "" : "—"
        subLabel: ""
        accentColor: Theme.resolveBatteryGaugeColor(root.config, root.widgetId, root.batteryFraction * 100, root.charging, root.accentColor)
        textColor: root.textColor
        subTextColor: Theme.resolveMutedColor(root.textColor)
        diameter: root.effectiveGaugeDiameter
      }
    Text {
      id: batterySummary
      x: root.compactLayout ? batteryGauge.width + 8 : 0
      y: root.compactLayout ? (parent.height - height) / 2 : batteryGauge.height + 10
      width: root.compactLayout ? parent.width - batteryGauge.width - 8 : parent.width
      height: 16
      text: root.compactLayout && root.profileError ? root.profileError : root.compactSummary
      textFormat: Text.PlainText
      color: root.compactLayout && root.profileError ? Color.urgent : Theme.resolveMutedColor(root.textColor)
      font.family: Style.font.family
      font.pixelSize: 11
      minimumPixelSize: 10
      fontSizeMode: Text.Fit
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      maximumLineCount: 1
      elide: Text.ElideRight
      Accessible.role: Accessible.StaticText
      Accessible.name: root.profileError || root.compactSummary
    }
    }

    Row {
      id: profileRow
      width: parent.width
      spacing: 6
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.profilesVisible

      Repeater {
        model: root.profiles

        Rectangle {
          required property var modelData
          required property int index

          // Share the exact available row width so every pill remains equal.
          width: (profileRow.width - Math.max(0, root.profiles.length - 1) * profileRow.spacing)
            / Math.max(1, root.profiles.length)
          height: 26
          radius: 13
          opacity: 1
          activeFocusOnTab: true
          Accessible.role: Accessible.Button
          Accessible.name: "Set power profile to " + String(modelData)
          Accessible.description: root.pendingProfile ? "Changing power profile" : ""
          Keys.onReturnPressed: root.setProfile(modelData)
          Keys.onSpacePressed: root.setProfile(modelData)
          color: {
            var name = String(modelData)
            var isActive = root.profileMatches(name, root.displayedProfile)
            return isActive
              ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.3)
              : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.05)
          }
          Behavior on color { ColorAnimation { duration: 180 } }
          border.color: {
            var name = String(modelData)
            var isActive = root.profileMatches(name, root.displayedProfile)
            return isActive ? root.accentColor : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.08)
          }
          Behavior on border.color { ColorAnimation { duration: 180 } }
          border.width: isActive2() ? 1.5 : 1

          function isActive2() {
            var name = String(modelData)
            return root.profileMatches(name, root.displayedProfile)
          }

          Text {
            anchors.fill: parent
            anchors.margins: 2
            textFormat: Text.PlainText
            text: root.profileLabel(modelData)
            color: parent.isActive2() ? root.accentColor : Theme.resolveMutedColor(root.textColor)
            font.family: Style.font.family
            font.pixelSize: 10
            minimumPixelSize: 9
            fontSizeMode: Text.Fit
            font.weight: parent.isActive2() ? Font.DemiBold : Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            maximumLineCount: 1
            elide: Text.ElideRight
            clip: true
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setProfile(modelData)
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: root.profileError !== "" && !root.compactLayout
      textFormat: Text.PlainText
      text: root.profileError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: 10
      horizontalAlignment: Text.AlignHCenter
      wrapMode: root.requestedHeight > 0 ? Text.NoWrap : Text.WordWrap
      elide: Text.ElideRight
      Accessible.name: root.profileError
    }
  }
}
