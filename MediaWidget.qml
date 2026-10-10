import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "WidgetConfig.js" as Config
import "WidgetTheme.js" as Theme
import "SamplingModel.js" as Sampling
import "WidgetSizing.js" as Sizing

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
  property bool samplingEnabled: true
  property real samplingMultiplier: 1
  readonly property bool samplingActive: root.samplingEnabled && root.visible

  readonly property var widgetCfg: Config.widgetConfig(root.config, root.widgetId) || {}
  readonly property bool showAlbumArt: root.widgetCfg.showAlbumArt !== false
  readonly property bool showControls: root.widgetCfg.showControls !== false
  readonly property real widgetCardWidth: Number(root.widgetCfg.cardWidth) || 0

  color: root.cardColor
  borderSpec: Border.surfaceSpec("widget", "border", root.borderColor, 1)
  radius: root.cardRadius
  padding: 0

  width: widgetCardWidth > 0 ? widgetCardWidth : 340
  // Auto keeps the original footprint in every playback state. These defaults
  // must not depend on the compressed rows, content height, or resolved height.
  readonly property real naturalCardHeight: 64 + 20 + 14 + (root.showControls ? 44 + 14 : 0) + 24
  readonly property real minimumCardHeight: root.showControls ? 100 : 80
  height: Sizing.cardHeight(root.widgetCfg.cardHeight, root.naturalCardHeight, root.minimumCardHeight)

  readonly property bool compactLayout: root.height < root.naturalCardHeight
  readonly property bool inlineControls: root.compactLayout && root.showControls && root.width >= 360
  readonly property bool compactMetadata: root.compactLayout && !root.inlineControls && root.height < 140
  readonly property bool stackedArtwork: root.showAlbumArt && root.width < 280 && root.height >= 260
  readonly property real contentMargin: root.compactLayout ? 6 : 16
  readonly property real contentInsets: root.compactLayout ? 12 : 24
  readonly property real layoutSpacing: root.compactLayout ? 4 : 14
  readonly property real seekRowHeight: root.compactLayout ? 24 : 20
  readonly property real transportButtonSize: root.compactLayout
    ? Math.max(28, Math.min(44, 28 + (root.height - root.minimumCardHeight) / 4)) : 44
  readonly property real transportSpacing: root.compactLayout ? 4 : 8
  readonly property real metadataHeight: root.compactMetadata ? 28 : 54
  readonly property real trackRowHeight: root.compactLayout
    ? root.height - root.contentInsets - root.seekRowHeight - root.layoutSpacing
      - (root.showControls && !root.inlineControls ? root.transportButtonSize + root.layoutSpacing : 0)
    : (root.stackedArtwork
      ? Math.min(root.width - 2 * root.contentMargin + root.metadataHeight + root.layoutSpacing,
          root.height - root.contentInsets - root.seekRowHeight - root.layoutSpacing
            - (root.showControls ? root.transportButtonSize + root.layoutSpacing : 0))
      : Math.min(128, 64 + Math.max(0, root.height - root.naturalCardHeight)))
  readonly property real artworkDiameter: root.stackedArtwork
    ? root.trackRowHeight - root.metadataHeight - root.layoutSpacing
    : Math.min(root.trackRowHeight, Math.max(28, root.width - 2 * root.contentMargin - root.layoutSpacing
        - (root.inlineControls ? 3 * root.transportButtonSize + 2 * root.transportSpacing + root.layoutSpacing : 0) - 90))
  // Reserve seek space for unknown durations too; metadata/state cannot change
  // the card's height or introduce a content -> height -> content binding loop.
  readonly property real playbackContentHeight: root.trackRowHeight + root.seekRowHeight + root.layoutSpacing
    + (root.showControls && !root.inlineControls ? root.transportButtonSize + root.layoutSpacing : 0)

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
    if (!p) return ""
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
  readonly property string artworkRequestKey: root.playerKey(root.activePlayer) + "\n"
    + root.title + "\n" + root.artist + "\n" + root.album + "\n" + root.artUrl
  property string artworkSource: ""
  property var artworkProcess: null

  function refreshArtwork() {
    if (root.artworkProcess) {
      root.artworkProcess.running = false
      root.artworkProcess.destroy()
      root.artworkProcess = null
    }
    root.artworkSource = ""
    if (root.samplingActive === false || !root.showAlbumArt || !root.hasMedia) return

    var url = String(root.artUrl)
    if ((url.startsWith("/") && !url.startsWith("//"))
        || /^file:\/\/\/[^\/\\]/i.test(url)) {
      root.artworkSource = url
      return
    }
    if (!/^https:\/\//i.test(url)) return

    var helper = decodeURIComponent(String(Qt.resolvedUrl("fetch_album_art.py")).replace(/^file:\/\//, ""))
    var process = artworkProcessComponent.createObject(root, {
      requestKey: root.artworkRequestKey,
      command: ["python3", helper, url]
    })
    if (!process) return
    root.artworkProcess = process
    process.running = true
  }

  onArtworkRequestKeyChanged: root.refreshArtwork()
  onShowAlbumArtChanged: root.refreshArtwork()

  Component {
    id: artworkProcessComponent
    Process {
      id: artworkFetch
      property string requestKey: ""
      property bool stdoutReady: false
      property bool exitReady: false
      property int exitCode: -1
      property string resultUrl: ""
      function finish() {
        if (!stdoutReady || !exitReady) return
        if (root.artworkProcess === artworkFetch) {
          if (exitCode === 0 && requestKey === root.artworkRequestKey
              && /^file:\/\/\/[^\r\n]+$/.test(resultUrl)) {
            root.artworkSource = resultUrl
          }
          root.artworkProcess = null
        }
        artworkFetch.destroy()
      }
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          artworkFetch.resultUrl = String(text || "").trim()
          artworkFetch.stdoutReady = true
          artworkFetch.finish()
        }
      }
      onExited: function(code) {
        artworkFetch.exitCode = code
        artworkFetch.exitReady = true
        artworkFetch.finish()
      }
    }
  }
  readonly property string identity: activePlayer ? (activePlayer.identity || activePlayer.desktopEntry || "") : ""
  readonly property bool isPlaying: activePlayer ? activePlayer.isPlaying : false

  // ── Position tracking (seconds, not microseconds) ──

  readonly property real trackLength: activePlayer && activePlayer.length ? activePlayer.length : 0
  readonly property bool canSeek: !!(activePlayer && activePlayer.canSeek
    && activePlayer.positionSupported && trackLength > 0)
  property real livePosition: 0
  property real positionSampleAt: Date.now()
  property bool seeking: false
  property real seekPreview: 0
  readonly property real shownPosition: seeking ? seekPreview : livePosition
  readonly property real progress: trackLength > 0 ? Math.max(0, Math.min(1, shownPosition / trackLength)) : 0

  function syncPosition() {
    root.positionSampleAt = Date.now()
    if (!root.samplingActive || root.seeking) return
    root.livePosition = root.activePlayer && root.activePlayer.position >= 0
      ? root.activePlayer.position : 0
  }
  onSamplingActiveChanged: {
    root.seeking = false
    root.syncPosition()
    root.refreshArtwork()
  }
  onIsPlayingChanged: root.syncPosition()

  // Sync from real MPRIS position when it changes
  Connections {
    target: root.activePlayer
    ignoreUnknownSignals: true
    function onPositionChanged() {
      root.syncPosition()
    }
    function onTrackTitleChanged() {
      root.syncPosition()
    }
    function onLengthChanged() {
      root.syncPosition()
    }
  }

  // Reset when active player changes
  onActivePlayerChanged: {
    root.syncPosition()
  }

  Component.onCompleted: {
    root.refreshArtwork()
    root.syncPosition()
  }

  // Use elapsed time so slowing the timer does not slow track progress.
  Timer {
    id: positionTimer
    objectName: "mediaPositionTimer"
    interval: Sampling.interval(1000, root.samplingMultiplier)
    repeat: true
    running: root.samplingActive && root.isPlaying && root.trackLength > 0
    onTriggered: {
      var now = Date.now()
      root.livePosition = Math.min(root.trackLength,
        root.livePosition + Math.max(0, now - root.positionSampleAt) / 1000)
      root.positionSampleAt = now
    }
  }

  // Periodic sync to correct drift (many players don't emit positionChanged)
  Timer {
    id: positionSyncTimer
    objectName: "mediaPositionSyncTimer"
    interval: Sampling.interval(5000, root.samplingMultiplier)
    repeat: true
    running: root.samplingActive && root.hasMedia && root.activePlayer !== null
    onTriggered: {
      if (root.activePlayer && root.activePlayer.position >= 0) {
        var realPos = root.activePlayer.position
        var diff = Math.abs(realPos - root.livePosition)
        if (diff > 3) {
          root.livePosition = realPos
          root.positionSampleAt = Date.now()
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
    root.positionSampleAt = Date.now()
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

  Item {
    id: content
    objectName: "widgetSizingContent"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: root.contentMargin
    anchors.rightMargin: root.contentMargin
    anchors.topMargin: root.hasMedia
      ? root.contentMargin + Math.max(0, (root.height - root.contentInsets - root.playbackContentHeight) / 2)
      : root.contentMargin
    height: root.hasMedia ? root.playbackContentHeight : root.height - 2 * root.contentMargin

    // --- Placeholder when no media ---
    Item {
      width: parent.width
      height: root.height - 2 * content.anchors.topMargin
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
    Item {
      id: trackInfo
      objectName: "mediaTrackInfo"
      visible: root.hasMedia
      width: parent.width
      height: root.trackRowHeight

      // Album art thumbnail
      Rectangle {
        id: artBox
        objectName: "mediaArtwork"
        width: root.showAlbumArt ? root.artworkDiameter : 0
        height: width
        x: root.stackedArtwork ? (parent.width - width) / 2 : 0
        y: root.stackedArtwork ? 0 : (parent.height - height) / 2
        radius: Math.min(12, width / 4)
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.06)
        clip: true
        visible: root.showAlbumArt

        Image {
          id: artImage
          anchors.fill: parent
          source: root.artworkSource
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: 128
          sourceSize.height: 128
          visible: root.artworkSource !== "" && status === Image.Ready
        }

        ArtworkPlaceholder {
          anchors.fill: parent
          accentColor: root.accentColor
          textColor: root.textColor
          visible: !artImage.visible
        }
      }

      // Title + artist + player name
      Column {
        id: metadata
        objectName: "mediaMetadata"
        x: root.stackedArtwork ? 0 : artBox.width + (root.showAlbumArt ? root.layoutSpacing : 0)
        y: root.stackedArtwork ? artBox.height + root.layoutSpacing : (parent.height - height) / 2
        width: parent.width - x
          - (root.inlineControls ? transportRow.width + root.layoutSpacing : 0)
        height: root.metadataHeight
        spacing: root.compactMetadata ? 0 : 4

        Text {
          objectName: "mediaTitle"
          textFormat: Text.PlainText
          text: root.title
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: root.compactMetadata ? 12 : 14
          font.bold: true
          height: root.compactMetadata ? 14 : 18
          lineHeightMode: Text.FixedHeight
          lineHeight: height
          elide: Text.ElideRight
          width: parent.width
          Accessible.role: Accessible.StaticText
          Accessible.name: root.title
        }

        Text {
          objectName: "mediaArtist"
          textFormat: Text.PlainText
          text: root.compactMetadata
            ? root.artist + (root.artist && root.identity ? " · " : "") + root.identity : root.artist
          color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
          font.family: Style.font.family
          font.pixelSize: root.compactMetadata ? 10 : 11
          height: 14
          lineHeightMode: Text.FixedHeight
          lineHeight: height
          elide: Text.ElideRight
          width: parent.width
          Accessible.role: Accessible.StaticText
          Accessible.name: text
        }

        Text {
          objectName: "mediaIdentity"
          textFormat: Text.PlainText
          text: root.identity
          color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: 10
          height: 14
          lineHeightMode: Text.FixedHeight
          lineHeight: height
          elide: Text.ElideRight
          width: parent.width
          visible: !root.compactMetadata && text !== ""
          Accessible.role: Accessible.StaticText
          Accessible.name: root.identity
        }
      }
    }

    // --- Seekable progress bar ---
    Item {
      id: seekRow
      objectName: "mediaSeekRow"
      width: parent.width
      height: root.seekRowHeight
      y: trackInfo.height + root.layoutSpacing
      visible: root.hasMedia && root.trackLength > 0

      MouseArea {
        id: seekArea
        objectName: "mediaSeekArea"
        x: progressTrack.x
        width: progressTrack.width
        height: Math.max(24, parent.height)
        anchors.verticalCenter: parent.verticalCenter
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
        objectName: "mediaProgressTrack"
        x: root.compactLayout ? elapsedTime.width + 6 : 0
        y: root.compactLayout ? (parent.height - height) / 2 : 0
        width: root.compactLayout ? parent.width - x - durationTime.width - 6 : parent.width
        height: 5
        radius: 2.5
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.1)
      }

      Rectangle {
        x: progressTrack.x
        y: progressTrack.y
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
        // Clamp the thumb inside the track at both ends, including tiny cards.
        y: progressTrack.y - 2.5
        x: progressTrack.x + Math.max(0, Math.min(progressTrack.width - width, progressTrack.width * root.progress - 5))
        visible: seekArea.containsMouse || seekArea.pressed
      }

      Text {
        id: elapsedTime
        objectName: "mediaElapsedTime"
        textFormat: Text.PlainText
        text: root.formatTime(root.shownPosition)
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
        font.family: Style.font.family
        font.pixelSize: 10
        width: Math.min(implicitWidth, parent.width * 0.22)
        height: 14
        elide: Text.ElideRight
        Accessible.name: text
        anchors.left: parent.left
        y: root.compactLayout ? (parent.height - height) / 2 : 6
      }

      Text {
        id: durationTime
        objectName: "mediaDurationTime"
        textFormat: Text.PlainText
        text: root.formatTime(root.trackLength)
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
        font.family: Style.font.family
        font.pixelSize: 10
        width: Math.min(implicitWidth, parent.width * 0.22)
        height: 14
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        Accessible.name: text
        anchors.right: parent.right
        y: root.compactLayout ? (parent.height - height) / 2 : 6
      }
    }

    // --- Controls: prev / play-pause / next ---
    Row {
      id: transportRow
      objectName: "mediaTransportRow"
      spacing: root.transportSpacing
      x: root.inlineControls ? parent.width - width : (parent.width - width) / 2
      y: root.inlineControls ? (trackInfo.height - height) / 2
        : trackInfo.height + root.layoutSpacing + (seekRow.visible ? seekRow.height + root.layoutSpacing : 0)
      visible: root.showControls && root.hasMedia
      height: root.transportButtonSize

      // Previous
      Item {
        id: previousButton
        objectName: "mediaPreviousButton"
        width: root.transportButtonSize
        height: width
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
          font.pixelSize: root.compactLayout ? 16 : 20
          anchors.centerIn: parent
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
        objectName: "mediaPlayPauseButton"
        width: root.transportButtonSize
        height: width
        radius: width / 2
        color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.18)
        border.color: activeFocus
          ? root.accentColor
          : Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.5)
        border.width: activeFocus ? 2.5 : 1.5
        anchors.verticalCenter: parent.verticalCenter
        enabled: root.canRunAction("playPause", root.activePlayer)
        activeFocusOnTab: enabled
        opacity: enabled ? 1 : 0.32
        Accessible.role: Accessible.Button
        Accessible.name: root.isPlaying ? "Pause" : "Play"
        Accessible.onPressAction: if (enabled) root.runAction("playPause")

        Keys.onReturnPressed: if (enabled) root.runAction("playPause")
        Keys.onEnterPressed: if (enabled) root.runAction("playPause")
        Keys.onSpacePressed: if (enabled) root.runAction("playPause")

        Text {
          textFormat: Text.PlainText
          text: root.isPlaying ? "󰏤" : "󰐊"
          color: root.accentColor
          font.family: Style.font.family
          font.pixelSize: root.compactLayout ? 16 : 20
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
        objectName: "mediaNextButton"
        width: root.transportButtonSize
        height: width
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
          font.pixelSize: root.compactLayout ? 16 : 20
          anchors.centerIn: parent
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
