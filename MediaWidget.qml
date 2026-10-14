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
// Idle browser-proxy players without track titles are skipped.
//
// Fresh D-Bus snapshots recover silent repeats and late duration updates.
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
  readonly property real transportButtonSize: Math.min(
    (root.width - 2 * root.contentMargin - (root.inlineControls ? 3 : 4) * root.transportSpacing)
      / (root.inlineControls ? 4 : 5),
    root.compactLayout ? Math.max(28, Math.min(44, 28 + (root.height - root.minimumCardHeight) / 4)) : 44)
  readonly property real transportSpacing: root.compactLayout ? 4
    : Math.min(8, Math.max(4, (root.width - 2 * root.contentMargin - 5 * 28) / 4))
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
        - (root.inlineControls ? 4 * root.transportButtonSize + 3 * root.transportSpacing + root.layoutSpacing : 0) - 90))
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
    var playingWithoutMetadata = null
    var playingProxyWithoutMetadata = null
    var paused = null
    var pausedProxy = null
    var pausedWithoutMetadata = null
    var pausedProxyWithoutMetadata = null
    var any = null

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue

      // Ignore idle browser proxies, but keep title-less audio/live streams.
      var entry = String(p.desktopEntry || p.identity || "")
      if (entry.indexOf("plasma-browser") !== -1 && !p.trackTitle && !p.isPlaying
          && p.playbackState !== MprisPlaybackState.Paused) continue

      var proxy = isProxyPlayer(p)
      var hasMeta = hasTrackMetadata(p)

      if (p.isPlaying && hasMeta) {
        if (!proxy) { playing = p; }
        else if (!playingProxy) { playingProxy = p; }
      } else if (p.isPlaying) {
        if (!proxy && !playingWithoutMetadata) playingWithoutMetadata = p
        else if (proxy && !playingProxyWithoutMetadata) playingProxyWithoutMetadata = p
      } else if (hasMeta) {
        if (!proxy && !paused) { paused = p; }
        else if (proxy && !pausedProxy) { pausedProxy = p; }
      } else if (p.playbackState === MprisPlaybackState.Paused) {
        if (!proxy && !pausedWithoutMetadata) pausedWithoutMetadata = p
        else if (proxy && !pausedProxyWithoutMetadata) pausedProxyWithoutMetadata = p
      } else if (!any) {
        any = p
      }
    }

    return playing || playingProxy || playingWithoutMetadata || playingProxyWithoutMetadata
      || paused || pausedProxy || pausedWithoutMetadata || pausedProxyWithoutMetadata || any || null
  }

  // A player can clear metadata during a track change or play a live stream
  // without a title. Keep transport available while playback is active.
  readonly property bool hasMedia: activePlayer !== null
    && (hasTrackMetadata(activePlayer) || activePlayer.isPlaying
      || activePlayer.playbackState === MprisPlaybackState.Paused)
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

  // Without lengthSupported Quickshell returns position as length, not a
  // duration. Never expose that fallback as a seekable, 100%-filled track.
  readonly property real trackLength: root.timingSnapshot ? root.timingSnapshot.length
    : activePlayer && activePlayer.lengthSupported
    && isFinite(Number(activePlayer.length))
    && Number(activePlayer.length) > 0 ? Number(activePlayer.length) : 0
  readonly property bool durationAvailable: root.trackLength > 0
  readonly property bool positionAvailable: root.timingSnapshot ? root.timingSnapshot.position !== null
    : !!(root.activePlayer && root.activePlayer.positionSupported
    && isFinite(Number(root.activePlayer.position)) && Number(root.activePlayer.position) >= 0)
  readonly property bool timelineAvailable: root.hasMedia
  readonly property bool canSeek: !!(activePlayer && activePlayer.canSeek
    && root.positionAvailable && root.durationAvailable)
  property real livePosition: 0
  property real positionSampleAt: Date.now()
  property bool seeking: false
  property real seekPreview: 0
  readonly property real shownPosition: seeking ? seekPreview : livePosition
  readonly property real progress: root.durationAvailable && root.positionAvailable
    ? Math.max(0, Math.min(1, shownPosition / trackLength)) : 0

  property var timingSnapshot: null
  property real timingSnapshotAt: 0
  property int timingEpoch: 0
  property var timingProcess: null
  readonly property string timingKey: root.playerKey(root.activePlayer) + "\n"
    + (root.activePlayer ? root.activePlayer.uniqueId : "") + "\n" + root.title
  onTimingKeyChanged: {
    root.invalidateTiming()
    root.syncPosition()
    root.requestTiming()
  }

  function invalidateTiming() {
    root.timingEpoch += 1
    root.timingSnapshot = null
  }

  function applyTiming(sample, key, epoch) {
    if (key !== root.timingKey || epoch !== root.timingEpoch || root.seeking || !root.activePlayer) return false
    if (!sample || (sample.position !== null && (!isFinite(sample.position) || sample.position < 0))
        || !isFinite(sample.length) || sample.length < 0) return false
    if (sample.title !== String(root.activePlayer.trackTitle || "")) return false
    var metadata = root.activePlayer.metadata || {}
    // Qt exposes an object-path variant as an opaque object, whose String()
    // includes a QVariant wrapper rather than the D-Bus path. Compare only
    // plain strings; timingKey/uniqueId and title still guard opaque variants.
    if (sample.trackId && typeof metadata["mpris:trackid"] === "string"
        && sample.trackId !== metadata["mpris:trackid"]) return false
    root.timingSnapshotAt = Date.now()
    root.timingSnapshot = sample
    root.syncPosition()
    return true
  }

  function requestTiming() {
    if (!root.samplingActive || !root.hasMedia || root.seeking || root.timingProcess) return
    var helper = decodeURIComponent(String(Qt.resolvedUrl("media_snapshot.py")).replace(/^file:\/\//, ""))
    var process = timingProcessComponent.createObject(root, {
      requestKey: root.timingKey, requestEpoch: root.timingEpoch,
      command: ["python3", helper, root.playerKey(root.activePlayer)]
    })
    if (!process) return
    root.timingProcess = process
    process.running = true
  }

  Component {
    id: timingProcessComponent
    Process {
      id: timingFetch
      property string requestKey: ""
      property int requestEpoch: 0
      property bool stdoutReady: false
      property bool exitReady: false
      property int exitCode: -1
      property string result: ""
      function finish() {
        if (!stdoutReady || !exitReady) return
        if (root.timingProcess === timingFetch) {
          if (exitCode === 0) {
            try { root.applyTiming(JSON.parse(result), requestKey, requestEpoch) } catch (_) {}
          }
          root.timingProcess = null
        }
        timingFetch.destroy()
      }
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          timingFetch.result = text
          timingFetch.stdoutReady = true
          timingFetch.finish()
        }
      }
      onExited: function(code) {
        timingFetch.exitCode = code
        timingFetch.exitReady = true
        timingFetch.finish()
      }
    }
  }

  function syncPosition() {
    root.positionSampleAt = Date.now()
    if (root.seeking) return
    // Reading the cached signal value is safe while periodic sampling is
    // paused, and prevents a previous player's progress surviving a switch.
    if (root.timingSnapshot) {
      var sample = root.timingSnapshot
      var elapsed = Math.max(0, Date.now() - root.timingSnapshotAt) / 1000
      // Stop extrapolating if fresh reads fail. Never run an old sample forever.
      elapsed = Math.min(elapsed, Sampling.interval(2000, root.samplingMultiplier) / 1000)
      var value = sample.position === null ? 0 : sample.position
        + (root.isPlaying && sample.playing && sample.length > 0 ? elapsed * sample.rate : 0)
      root.livePosition = sample.length > 0 ? Math.min(sample.length, value) : value
      return
    }
    var player = root.activePlayer
    var position = player ? Number(player.position) : -1
    root.livePosition = player && player.positionSupported && isFinite(position) && position >= 0 ? position : 0
  }
  onSamplingActiveChanged: {
    root.invalidateTiming()
    root.requestTiming()
    root.seeking = false
    root.syncPosition()
    root.refreshArtwork()
  }
  onIsPlayingChanged: {
    root.invalidateTiming()
    root.syncPosition()
    root.requestTiming()
  }

  // Sync from real MPRIS position when it changes
  Connections {
    target: root.activePlayer
    ignoreUnknownSignals: true
    function onPositionChanged() {
      // Other shell consumers emit this signal to animate the cached getter.
      // It is not proof of a fresh D-Bus sample; keep our authoritative anchor.
      root.syncPosition()
    }
    function onTrackTitleChanged() {
      root.seeking = false
      root.seekPreview = 0
      root.syncPosition()
    }
    function onPostTrackChanged() {
      root.seeking = false
      root.seekPreview = 0
      root.syncPosition()
    }
    function onLengthChanged() {
      // Without lengthSupported, Quickshell emits lengthChanged for position.
      if (root.activePlayer && root.activePlayer.lengthSupported
          && (!root.timingSnapshot || root.activePlayer.length !== root.timingSnapshot.length)) {
        root.invalidateTiming()
      }
      root.syncPosition()
    }
    function onPositionSupportedChanged() {
      root.seeking = false
      root.syncPosition()
    }
  }

  // Reset when active player changes
  onActivePlayerChanged: {
    root.invalidateTiming()
    root.seeking = false
    root.seekPreview = 0
    root.syncPosition()
  }

  Component.onCompleted: {
    root.refreshArtwork()
    root.syncPosition()
  }

  // Quickshell already interpolates position using the playback rate. Read it
  // on each tick instead of adding wall time at an assumed 1x speed.
  Timer {
    id: positionTimer
    objectName: "mediaPositionTimer"
    interval: Sampling.interval(1000, root.samplingMultiplier)
    repeat: true
    running: root.samplingActive && root.isPlaying && root.positionAvailable && !root.seeking
    onTriggered: root.syncPosition()
  }

  // Read the player over D-Bus: Quickshell's position getter is an
  // extrapolated cache and cannot detect repeats without a Seeked signal.
  Timer {
    id: positionSyncTimer
    objectName: "mediaPositionSyncTimer"
    interval: Sampling.interval(2000, root.samplingMultiplier)
    repeat: true
    running: root.samplingActive && root.hasMedia && root.activePlayer !== null
    triggeredOnStart: true
    onTriggered: root.requestTiming()
  }

  // ── Controls ──
  // Transport actions intentionally target the exact player rendered by this
  // card. Never fall back to a global media action: with multiple players that
  // could control a different source than the one named above the controls.
  readonly property int loopState: root.activePlayer && root.activePlayer.loopSupported
    ? root.activePlayer.loopState : MprisLoopState.None

  function canRunAction(action, player) {
    if (!player) return false
    if (action === "loop") return !!(player.canControl && player.loopSupported)
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

    if (action === "loop") {
      player.loopState = player.loopState === MprisLoopState.None ? MprisLoopState.Playlist
        : player.loopState === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None
    }
    else if (action === "previous") player.previous()
    else if (action === "next") player.next()
    else if (player.isPlaying && player.canPause) player.pause()
    else if (!player.isPlaying && player.canPlay) player.play()
    else player.togglePlaying()
    return true
  }

  function previewSeek(fraction) {
    if (!root.canSeek) return
    root.timingEpoch += 1
    root.seeking = true
    root.seekPreview = Math.max(0, Math.min(trackLength, fraction * trackLength))
  }

  function commitSeek() {
    if (!root.seeking) return
    if (!root.canSeek) {
      root.seeking = false
      root.seekPreview = 0
      root.syncPosition()
      return
    }
    var newPos = root.seekPreview
    root.invalidateTiming()
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

    // --- Stable timeline; timing and seeking depend on player capabilities ---
    Item {
      id: seekRow
      objectName: "mediaSeekRow"
      width: parent.width
      height: root.seekRowHeight
      y: trackInfo.height + root.layoutSpacing
      visible: root.timelineAvailable
      Accessible.role: Accessible.StaticText
      Accessible.name: "Playback timeline"
      Accessible.description: !root.durationAvailable ? "Track duration unavailable from this player"
        : !root.positionAvailable ? "Playback position unavailable from this player" : ""

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
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.2)
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
        visible: root.canSeek && (seekArea.containsMouse || seekArea.pressed)
      }

      Text {
        id: elapsedTime
        objectName: "mediaElapsedTime"
        textFormat: Text.PlainText
        text: root.positionAvailable ? root.formatTime(root.shownPosition) : "--:--"
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
        text: root.durationAvailable ? root.formatTime(root.trackLength) : "--:--"
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

    // Keep the primary three controls centered; repeat occupies a side slot.
    Item {
      id: transportRow
      objectName: "mediaTransportRow"
      width: (root.inlineControls ? 4 : 5) * root.transportButtonSize
        + (root.inlineControls ? 3 : 4) * root.transportSpacing
      x: root.inlineControls ? parent.width - width : (parent.width - width) / 2
      y: root.inlineControls ? (trackInfo.height - height) / 2
        : trackInfo.height + root.layoutSpacing + seekRow.height + root.layoutSpacing
      visible: root.showControls && root.hasMedia
      height: root.transportButtonSize

      // Previous
      Item {
        id: previousButton
        x: (0 + (root.inlineControls ? 0 : 1)) * (root.transportButtonSize + root.transportSpacing)
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
        x: (1 + (root.inlineControls ? 0 : 1)) * (root.transportButtonSize + root.transportSpacing)
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
        x: (2 + (root.inlineControls ? 0 : 1)) * (root.transportButtonSize + root.transportSpacing)
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

      // Repeat: off → playlist → track → off
      Item {
        id: loopButton
        x: (3 + (root.inlineControls ? 0 : 1)) * (root.transportButtonSize + root.transportSpacing)
        objectName: "mediaLoopButton"
        width: root.transportButtonSize
        height: width
        anchors.verticalCenter: parent.verticalCenter
        enabled: root.canRunAction("loop", root.activePlayer)
        activeFocusOnTab: enabled
        opacity: enabled ? 1 : 0.32
        Accessible.role: Accessible.Button
        Accessible.name: !enabled ? "Repeat unavailable for this player"
          : root.loopState === MprisLoopState.Track ? "Repeat track; activate to turn off"
          : root.loopState === MprisLoopState.Playlist ? "Repeat playlist; activate to repeat track"
          : "Repeat off; activate to repeat playlist"
        Accessible.onPressAction: if (enabled) root.runAction("loop")

        Keys.onReturnPressed: if (enabled) root.runAction("loop")
        Keys.onEnterPressed: if (enabled) root.runAction("loop")
        Keys.onSpacePressed: if (enabled) root.runAction("loop")

        Rectangle {
          anchors.fill: parent
          anchors.margins: 3
          radius: 18
          color: loopButton.activeFocus
            ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.12)
            : "transparent"
          border.color: loopButton.activeFocus ? root.accentColor : "transparent"
          border.width: loopButton.activeFocus ? 1.5 : 0
        }

        Text {
          textFormat: Text.PlainText
          text: root.loopState === MprisLoopState.Track ? "󰑘" : "󰑖"
          color: root.loopState !== MprisLoopState.None ? root.accentColor
            : loopHover.containsMouse || loopButton.activeFocus ? root.textColor
            : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: root.compactLayout ? 16 : 20
          anchors.centerIn: parent
        }

        MouseArea {
          id: loopHover
          anchors.fill: parent
          hoverEnabled: true
          enabled: loopButton.enabled
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            loopButton.forceActiveFocus()
            root.runAction("loop")
          }
        }
      }
    }
  }
}
