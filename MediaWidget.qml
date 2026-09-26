import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "WidgetConfig.js" as Config
import "WidgetTheme.js" as Theme

// Media now-playing card.
// Player selection follows the same priority pattern as Omarchy's
// built-in media service (Service.qml):
//   1. Currently playing player with metadata
//   2. Player with metadata (paused)
//   3. Any player
// Proxy players (playerctld) are deprioritized.
// Browser-proxy players without track titles are skipped.
//
// Position tracking uses a 1-second Timer to interpolate forward
// while playing, with periodic sync to the real MPRIS position.
// Quickshell reports position/length in seconds (not microseconds).
BorderSurface {
  id: root

  property string widgetId: "media"
  property var config: ({})
  property color cardColor: Qt.rgba(0.09, 0.09, 0.10, 0.75)
  property color borderColor: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.15)
  property color textColor: Color.foreground
  property color accentColor: Color.accent
  property real cardRadius: 18
  property real gaugeDiameter: 120

  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property bool showAlbumArt: root.widgetCfg.showAlbumArt !== false
  readonly property bool showControls: root.widgetCfg.showControls !== false
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: 0

  width: widgetCardWidth > 0 ? widgetCardWidth : 340
  height: content.implicitHeight + 24

  // ── Player selection (mirrors Omarchy Service.qml logic) ──

  readonly property var players: Mpris.players ? Mpris.players.values : []

  // Reactive nonce: increments whenever any player's metadata or state changes.
  // The activePlayer binding depends on this so it re-evaluates when tracks
  // change, not just when players are added/removed.
  property int playerUpdateNonce: 0
  function bumpNonce() { root.playerUpdateNonce += 1 }

  // Watch each player for property changes (like Omarchy's Service.qml Instantiator)
  Instantiator {
    model: root.players
    delegate: Connections {
      required property var modelData
      target: modelData
      ignoreUnknownSignals: true
      function onTrackTitleChanged() { root.bumpNonce() }
      function onTrackArtistChanged() { root.bumpNonce() }
      function onTrackAlbumChanged() { root.bumpNonce() }
      function onTrackArtUrlChanged() { root.bumpNonce() }
      function onIsPlayingChanged() { root.bumpNonce() }
      function onLengthChanged() { root.bumpNonce() }
    }
  }

  function isProxyPlayer(p) {
    var dbus = String(p.dbusName || "")
    var entry = String(p.desktopEntry || "")
    return dbus.indexOf("playerctld") !== -1 || entry === "playerctld"
  }

  function hasTrackMetadata(p) {
    return !!(p && (p.trackTitle || p.trackArtist))
  }

  function playerKey(p) {
    return String(p.dbusName || p.identity || "")
  }

  readonly property var activePlayer: {
    // Touch the nonce so this binding re-evaluates on player property changes
    var _ = root.playerUpdateNonce
    var playing = null
    var playingProxy = null
    var paused = null
    var pausedProxy = null
    var any = null

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue

      // Skip browser-proxy players with no track title
      var entry = String(p.desktopEntry || p.identity || "")
      if (entry.indexOf("plasma-browser") !== -1 && !p.trackTitle) continue

      var proxy = isProxyPlayer(p)
      var hasMeta = hasTrackMetadata(p)

      if (p.isPlaying && hasMeta) {
        if (!proxy) { playing = p; }
        else if (!playingProxy) { playingProxy = p; }
      } else if (hasMeta) {
        if (!proxy && !paused) { paused = p; }
        else if (proxy && !pausedProxy) { pausedProxy = p; }
      } else if (!any) {
        any = p
      }
    }

    return playing || playingProxy || paused || pausedProxy || any || null
  }

  readonly property bool hasMedia: activePlayer !== null && hasTrackMetadata(activePlayer)
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "Unknown track") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string album: activePlayer && activePlayer.trackAlbum ? activePlayer.trackAlbum : ""
  readonly property string artUrl: activePlayer && activePlayer.trackArtUrl ? activePlayer.trackArtUrl : ""
  readonly property string identity: activePlayer ? (activePlayer.identity || activePlayer.desktopEntry || "") : ""
  readonly property bool isPlaying: activePlayer ? activePlayer.isPlaying : false

  // ── Position tracking (seconds, not microseconds) ──

  readonly property real trackLength: activePlayer && activePlayer.length ? activePlayer.length : 0
  readonly property bool canSeek: !!(activePlayer && activePlayer.canSeek
    && activePlayer.positionSupported && trackLength > 0)
  property real livePosition: 0
  property bool seeking: false
  property real seekPreview: 0
  readonly property real shownPosition: seeking ? seekPreview : livePosition
  readonly property real progress: trackLength > 0 ? Math.max(0, Math.min(1, shownPosition / trackLength)) : 0

  // Sync from real MPRIS position when it changes
  Connections {
    target: root.activePlayer
    ignoreUnknownSignals: true
    function onPositionChanged() {
      if (!root.seeking && root.activePlayer && root.activePlayer.position >= 0) {
        root.livePosition = root.activePlayer.position
      }
    }
    function onTrackTitleChanged() {
      root.livePosition = root.activePlayer ? (root.activePlayer.position || 0) : 0
    }
    function onLengthChanged() {
      root.livePosition = root.activePlayer ? (root.activePlayer.position || 0) : 0
    }
  }

  // Reset when active player changes
  onActivePlayerChanged: {
    root.livePosition = root.activePlayer ? (root.activePlayer.position || 0) : 0
  }

  Component.onCompleted: {
    if (root.activePlayer && root.activePlayer.position >= 0) {
      root.livePosition = root.activePlayer.position
    }
  }

  // Tick forward 1 second while playing
  Timer {
    id: positionTimer
    interval: 1000
    repeat: true
    running: root.isPlaying && root.trackLength > 0
    onTriggered: {
      if (root.livePosition < root.trackLength) {
        root.livePosition += 1
      } else {
        root.livePosition = root.trackLength
      }
    }
  }

  // Periodic sync to correct drift (many players don't emit positionChanged)
  Timer {
    id: positionSyncTimer
    interval: 5000
    repeat: true
    running: root.hasMedia && root.activePlayer !== null
    onTriggered: {
      if (root.activePlayer && root.activePlayer.position >= 0) {
        var realPos = root.activePlayer.position
        var diff = Math.abs(realPos - root.livePosition)
        if (diff > 3) {
          root.livePosition = realPos
        }
      }
    }
  }

  // ── Controls ──
  // Transport actions intentionally target the exact player rendered by this
  // card. Never fall back to a global media action: with multiple players that
  // could control a different source than the one named above the controls.
  function canRunAction(action, player) {
    if (!player) return false
    if (action === "previous") return !!player.canGoPrevious
    if (action === "next") return !!player.canGoNext
    if (action === "playPause") {
      return player.isPlaying
        ? !!(player.canPause || player.canTogglePlaying)
        : !!(player.canPlay || player.canTogglePlaying)
    }
    return false
  }

  function runAction(action) {
    var player = root.activePlayer
    if (!root.canRunAction(action, player)) return false

    if (action === "previous") player.previous()
    else if (action === "next") player.next()
    else if (player.isPlaying && player.canPause) player.pause()
    else if (!player.isPlaying && player.canPlay) player.play()
    else player.togglePlaying()
    return true
  }

  function previewSeek(fraction) {
    if (!root.canSeek) return
    root.seeking = true
    root.seekPreview = Math.max(0, Math.min(trackLength, fraction * trackLength))
  }

  function commitSeek() {
    if (!root.seeking) return
    var newPos = root.seekPreview
    root.seeking = false
    root.livePosition = newPos
    root.activePlayer.position = newPos
  }

  function formatTime(seconds) {
    seconds = Math.floor(seconds || 0)
    if (seconds < 0) return "0:00"
    var m = Math.floor(seconds / 60)
    var s = Math.floor(seconds % 60)
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  visible: true

  // ── Layout ──

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: 16
    anchors.rightMargin: 16
    anchors.topMargin: 16
    spacing: 14

    // --- Placeholder when no media ---
    Item {
      width: parent.width
      height: 56
      visible: !root.hasMedia

      Column {
        anchors.centerIn: parent
        spacing: 6

        Text {
          textFormat: Text.PlainText
          text: "♪"
          color: Theme.resolveMutedColor(root.textColor)
          font.family: Style.font.family
          font.pixelSize: 20
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: "Nothing playing"
          color: Theme.resolveMutedColor(root.textColor)
          font.family: Style.font.family
          font.pixelSize: 12
          anchors.horizontalCenter: parent.horizontalCenter
        }
      }
    }

    // --- Track info: art + title/artist ---
    Row {
      visible: root.hasMedia
      spacing: 14
      width: parent.width
      height: 64

      // Album art thumbnail
      Rectangle {
        id: artBox
        width: root.showAlbumArt ? 64 : 0
        height: 64
        radius: 12
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.06)
        clip: true
        visible: root.showAlbumArt

        Image {
          id: artImage
          anchors.fill: parent
          source: root.artUrl
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: 128
          sourceSize.height: 128
          visible: root.artUrl !== "" && status === Image.Ready
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "󰝚"
          color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.25)
          font.family: Style.font.family
          font.pixelSize: 28
          visible: !artImage.visible
        }
      }

      // Title + artist + player name
      Column {
        width: parent.width - artBox.width - (root.showAlbumArt ? 14 : 0)
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        Text {
          textFormat: Text.PlainText
          text: root.title
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: 14
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          text: root.artist
          color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
          font.family: Style.font.family
          font.pixelSize: 11
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          text: root.identity
          color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: 9
          elide: Text.ElideRight
          width: parent.width
          visible: text !== ""
        }
      }
    }

    // --- Seekable progress bar ---
    Item {
      width: parent.width
      height: 20
      visible: root.hasMedia && root.trackLength > 0

      MouseArea {
        id: seekArea
        anchors.fill: parent
        enabled: root.canSeek
        cursorShape: root.canSeek ? Qt.PointingHandCursor : Qt.ArrowCursor
        preventStealing: true
        function seekFromMouse(mouseX) {
          var fraction = Math.max(0, Math.min(1, mouseX / progressTrack.width))
          root.previewSeek(fraction)
        }
        onPressed: function(mouse) { seekFromMouse(mouse.x) }
        onPositionChanged: function(mouse) {
          if (pressed) seekFromMouse(mouse.x)
        }
        onReleased: root.commitSeek()
        onCanceled: root.seeking = false
      }

      Rectangle {
        id: progressTrack
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 5
        radius: 2.5
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.1)
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: progressTrack.width * root.progress
        height: 5
        radius: 2.5
        color: root.accentColor

      }

      Rectangle {
        width: 10
        height: 10
        radius: 5
        color: root.accentColor
        anchors.verticalCenter: parent.verticalCenter
        x: progressTrack.width * root.progress - 5
        visible: seekArea.containsMouse || seekArea.pressed
        scale: seekArea.pressed ? 1.3 : 1.0

        Behavior on scale { NumberAnimation { duration: 100 } }
      }

      Text {
        textFormat: Text.PlainText
        text: root.formatTime(root.shownPosition)
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
        font.family: Style.font.family
        font.pixelSize: 9
        anchors.left: parent.left
        anchors.top: progressTrack.bottom
        anchors.topMargin: 3
      }

      Text {
        textFormat: Text.PlainText
        text: root.formatTime(root.trackLength)
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
        font.family: Style.font.family
        font.pixelSize: 9
        anchors.right: parent.right
        anchors.top: progressTrack.bottom
        anchors.topMargin: 3
      }
    }

    // --- Controls: prev / play-pause / next ---
    Row {
      spacing: 8
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.showControls && root.hasMedia
      height: 44

      // Previous
      Item {
        id: previousButton
        width: 44
        height: 44
        anchors.verticalCenter: parent.verticalCenter
        enabled: root.canRunAction("previous", root.activePlayer)
        activeFocusOnTab: enabled
        opacity: enabled ? 1 : 0.32
        Accessible.role: Accessible.Button
        Accessible.name: "Previous track"
        Accessible.onPressAction: if (enabled) root.runAction("previous")

        Keys.onReturnPressed: if (enabled) root.runAction("previous")
        Keys.onEnterPressed: if (enabled) root.runAction("previous")
        Keys.onSpacePressed: if (enabled) root.runAction("previous")

        Rectangle {
          anchors.fill: parent
          anchors.margins: 3
          radius: 18
          color: previousButton.activeFocus
            ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.12)
            : "transparent"
          border.color: previousButton.activeFocus ? root.accentColor : "transparent"
          border.width: previousButton.activeFocus ? 1.5 : 0
        }

        Text {
          textFormat: Text.PlainText
          text: "󰒮"
          color: prevHover.containsMouse || previousButton.activeFocus ? root.textColor
            : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: 20
          anchors.centerIn: parent
          scale: prevHover.containsMouse ? 1.15 : 1.0
          Behavior on scale { NumberAnimation { duration: 100 } }
        }

        MouseArea {
          id: prevHover
          anchors.fill: parent
          hoverEnabled: true
          enabled: previousButton.enabled
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            previousButton.forceActiveFocus()
            root.runAction("previous")
          }
        }
      }

      // Play/Pause
      Rectangle {
        id: playPauseButton
        width: 44
        height: 44
        radius: 22
        color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.18)
        border.color: activeFocus
          ? root.accentColor
          : Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.5)
        border.width: activeFocus ? 2.5 : 1.5
        anchors.verticalCenter: parent.verticalCenter
        enabled: root.canRunAction("playPause", root.activePlayer)
        activeFocusOnTab: enabled
        opacity: enabled ? 1 : 0.32
        scale: playHover.containsMouse || activeFocus ? 1.08 : 1.0
        Accessible.role: Accessible.Button
        Accessible.name: root.isPlaying ? "Pause" : "Play"
        Accessible.onPressAction: if (enabled) root.runAction("playPause")

        Keys.onReturnPressed: if (enabled) root.runAction("playPause")
        Keys.onEnterPressed: if (enabled) root.runAction("playPause")
        Keys.onSpacePressed: if (enabled) root.runAction("playPause")

        Behavior on scale { NumberAnimation { duration: 100 } }

        Text {
          textFormat: Text.PlainText
          text: root.isPlaying ? "󰏤" : "󰐊"
          color: root.accentColor
          font.family: Style.font.family
          font.pixelSize: 20
          anchors.centerIn: parent
        }

        MouseArea {
          id: playHover
          anchors.fill: parent
          hoverEnabled: true
          enabled: playPauseButton.enabled
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            playPauseButton.forceActiveFocus()
            root.runAction("playPause")
          }
        }
      }

      // Next
      Item {
        id: nextButton
        width: 44
        height: 44
        anchors.verticalCenter: parent.verticalCenter
        enabled: root.canRunAction("next", root.activePlayer)
        activeFocusOnTab: enabled
        opacity: enabled ? 1 : 0.32
        Accessible.role: Accessible.Button
        Accessible.name: "Next track"
        Accessible.onPressAction: if (enabled) root.runAction("next")

        Keys.onReturnPressed: if (enabled) root.runAction("next")
        Keys.onEnterPressed: if (enabled) root.runAction("next")
        Keys.onSpacePressed: if (enabled) root.runAction("next")

        Rectangle {
          anchors.fill: parent
          anchors.margins: 3
          radius: 18
          color: nextButton.activeFocus
            ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.12)
            : "transparent"
          border.color: nextButton.activeFocus ? root.accentColor : "transparent"
          border.width: nextButton.activeFocus ? 1.5 : 0
        }

        Text {
          textFormat: Text.PlainText
          text: "󰒭"
          color: nextHover.containsMouse || nextButton.activeFocus ? root.textColor
            : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: 20
          anchors.centerIn: parent
          scale: nextHover.containsMouse ? 1.15 : 1.0
          Behavior on scale { NumberAnimation { duration: 100 } }
        }

        MouseArea {
          id: nextHover
          anchors.fill: parent
          hoverEnabled: true
          enabled: nextButton.enabled
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            nextButton.forceActiveFocus()
            root.runAction("next")
          }
        }
      }
    }
  }
}
