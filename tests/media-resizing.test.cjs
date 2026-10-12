const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const repository = path.resolve(__dirname, '..')
const shellDirectory = process.env.OMARCHY_SHELL_DIR || '/usr/share/omarchy/shell'
const hasQt = spawnSync('qs', ['--version'], { encoding: 'utf8' }).status === 0
  && fs.existsSync(path.join(shellDirectory, 'Commons'))

// Isolate only the MPRIS discovery binding in a temporary copy. The real
// selection, layout, theme, metadata, and controls run in Qt against QObject
// players. No production test hooks, running player actions, or shared fixture
// changes are needed. Run with MEDIA_TEST_IMAGE=/absolute/path.png to capture.
const fixture = `
import QtQuick
import QtTest
import Quickshell
import Quickshell.Services.Mpris
import "." as Plugin

ShellRoot {
  id: suite
  property bool ready: false
  Timer { interval: 150; running: true; onTriggered: suite.ready = true }
  component FixturePlayer: QtObject {
    property string dbusName: "org.mpris.MediaPlayer2.fixture"
    property string desktopEntry: "fixture"
    property string identity: "Fixture player with a long accessible name"
    property string trackTitle: "A very long <b>plain text</b> title that must elide in compact layouts"
    property string trackArtist: "An artist with a full name retained for accessibility"
    property string trackAlbum: "Fixture album"
    property string trackArtUrl: ""
    property bool isPlaying: true
    property int playbackState: isPlaying ? MprisPlaybackState.Playing : MprisPlaybackState.Paused
    property bool canGoPrevious: true
    property bool canGoNext: true
    property bool canPlay: true
    property bool canPause: true
    property bool canTogglePlaying: true
    property bool canSeek: true
    property bool positionSupported: true
    property real position: 55
    property real length: 180
    property string actions: ""
    function previous() { actions += "previous;" }
    function next() { actions += "next;" }
    function play() { actions += "play;"; isPlaying = true }
    function pause() { actions += "pause;"; isPlaying = false }
    function togglePlaying() { actions += "toggle;"; isPlaying = !isPlaying }
  }
  FixturePlayer { id: player }
  FixturePlayer {
    id: unknownPlayer
    dbusName: "org.mpris.MediaPlayer2.unknown"
    identity: "Unknown-duration player"
    trackTitle: "Live stream with unavailable timing"
    length: 0; position: -1; positionSupported: false; canSeek: false
  }
  FixturePlayer {
    id: noMetadataPlayer
    dbusName: "org.mpris.MediaPlayer2.noMetadata"
    identity: "Playing without track metadata"
    trackTitle: ""; trackArtist: ""; trackAlbum: ""
    length: 0; position: -1; positionSupported: false; canSeek: false
  }
  FloatingWindow {
    visible: true
    implicitWidth: 1120; implicitHeight: 740
    color: "#151821"
    Item {
      id: preview
      width: 1120; height: 740
      Rectangle { anchors.fill: parent; color: "#151821" }
      Plugin.MediaWidget { id: card; x: 10; y: 10; samplingEnabled: false }
      Plugin.MediaWidget {
        id: tall; x: 560; y: 10; samplingEnabled: false; visible: false
        players: [player]
        config: ({widgets:{media:{cardWidth:200,cardHeight:360}}})
      }
      Plugin.MediaWidget {
        id: narrow; x: 10; y: 210; samplingEnabled: false; visible: false
        players: [player]
        config: ({widgets:{media:{cardWidth:200,cardHeight:100}}})
      }
      Plugin.MediaWidget {
        id: wide; x: 10; y: 330; samplingEnabled: false; visible: false
        players: [player]
        config: ({widgets:{media:{cardWidth:500,cardHeight:100}}})
      }
      Plugin.MediaWidget {
        id: noControls; x: 240; y: 220; samplingEnabled: false; visible: false
        players: [player]
        config: ({widgets:{media:{cardWidth:280,cardHeight:80,showControls:false}}})
      }
      Plugin.MediaWidget {
        id: unknownAuto; x: 10; y: 540; samplingEnabled: false; visible: false
        players: [unknownPlayer]
        config: ({widgets:{media:{cardWidth:340,cardHeight:0}}})
      }
      Plugin.MediaWidget {
        id: unknownCompact; x: 560; y: 390; samplingEnabled: false; visible: false
        players: [unknownPlayer]
        config: ({widgets:{media:{cardWidth:200,cardHeight:100}}})
      }
      Plugin.MediaWidget {
        id: noMetadataAuto; x: 370; y: 540; samplingEnabled: false; visible: false
        players: [noMetadataPlayer]
        config: ({widgets:{media:{cardWidth:340,cardHeight:0}}})
      }
      Plugin.MediaWidget {
        id: noMetadataCompact; x: 780; y: 390; samplingEnabled: false; visible: false
        players: [noMetadataPlayer]
        config: ({widgets:{media:{cardWidth:200,cardHeight:100}}})
      }
      Plugin.MediaWidget {
        id: idle; x: 240; y: 450; samplingEnabled: false; visible: false
        config: ({widgets:{media:{cardWidth:280,cardHeight:80,showControls:false}}})
      }
    }
    TestCase {
      name: "MediaResizing"
      when: suite.ready
      property string assertionContext: ""
      function verifyReported(condition, message) {
        if (!condition) console.error("MEDIA_RESIZING_ASSERT", assertionContext, message || "verification failed")
        verify(condition, message)
      }
      function compareReported(actual, expected, message) {
        if (actual !== expected) console.error("MEDIA_RESIZING_ASSERT", assertionContext,
          message || "comparison failed", "actual:", actual, "expected:", expected)
        compare(actual, expected, message)
      }
      function configure(width, height, controls, artwork) {
        card.config = {widgets:{media:{cardWidth:width,cardHeight:height,showControls:controls,showAlbumArt:artwork}}}
      }
      function fits(item, label, target) {
        target = target || card
        verifyReported(item !== null, label + ": missing")
        var point = target.mapFromItem(item, 0, 0)
        verifyReported(point.x >= -0.1 && point.x + item.width <= target.width + 0.1, label + ": horizontal")
        verifyReported(point.y >= -0.1 && point.y + item.height <= target.height + 0.1, label + ": vertical")
      }
      function visibleChildrenFit(item, target) {
        if (!item.visible) return
        fits(item, item.objectName || item.toString(), target)
        for (var child of item.children) visibleChildrenFit(child, target)
      }
      function playbackFits(target, controls) {
        var timeline = findChild(target, "mediaSeekRow")
        verifyReported(timeline.visible, "timeline must remain visible")
        for (var name of ["mediaSeekRow", "mediaSeekArea", "mediaProgressTrack", "mediaElapsedTime", "mediaDurationTime"]) {
          var item = findChild(target, name)
          verifyReported(item.visible, name + ": hidden")
          fits(item, name, target)
        }
        visibleChildrenFit(timeline, target)
        var seek = findChild(target, "mediaSeekArea")
        verifyReported(seek.height >= 24 && seek.width >= 80)
        compareReported(seek.enabled, target.canSeek)
        var transport = findChild(target, "mediaTransportRow")
        compareReported(transport.visible, controls)
        if (controls) {
          visibleChildrenFit(transport, target)
          for (var name of ["mediaPreviousButton", "mediaPlayPauseButton", "mediaNextButton"]) {
            var button = findChild(target, name)
            verifyReported(button.visible && button.enabled)
            verifyReported(button.width >= 28 && button.height >= 28)
            compareReported(button.scale, 1)
          }
          var timelinePoint = target.mapFromItem(timeline, 0, 0)
          var transportPoint = target.mapFromItem(transport, 0, 0)
          verifyReported(transportPoint.y + transport.height <= timelinePoint.y + 0.1
            || transportPoint.y >= timelinePoint.y + timeline.height - 0.1,
            "transport overlaps timeline")
        }
      }
      function test_a_auto_compact_and_states() {
        for (var controls of [true, false]) {
          for (var artwork of [true, false]) {
            for (var width of [200, 330, 340, 359, 360, 500]) {
              for (var height of [0, 80, 100, 110, 120, 122, 139, 140, 160, 179, 180, 220, 259, 260, 360, 400, 1000]) {
                configure(width, height, controls, artwork)
                var stableRows = null
                for (var state of ["idle", "playing", "paused", "unknown duration", "playing without metadata", "paused without metadata", "unsupported seeking"]) {
                  assertionContext = width + "x" + height + ", controls=" + controls + ", artwork=" + artwork + ", " + state
                  var missingMetadata = state === "playing without metadata" || state === "paused without metadata"
                  player.isPlaying = state !== "paused" && state !== "paused without metadata" && state !== "idle"
                  player.length = state === "unknown duration" || missingMetadata ? 0 : 180
                  player.positionSupported = player.length > 0
                  player.position = player.positionSupported ? 55 : -1
                  player.canSeek = state !== "unsupported seeking" && player.positionSupported
                  player.trackTitle = missingMetadata ? "" : "A very long <b>plain text</b> title that must elide in compact layouts"
                  player.trackArtist = missingMetadata ? "" : "An artist with a full name retained for accessibility"
                  player.trackAlbum = missingMetadata ? "" : "Fixture album"
                  card.players = state === "idle" ? [] : [player]
                  wait(1)
                  var natural = controls ? 180 : 122
                  compareReported(card.naturalCardHeight, natural)
                  compareReported(card.height, height === 0 ? natural : Math.max(controls ? 100 : 80, height))
                  fits(findChild(card, "widgetSizingContent"), "content")
                  if (state === "idle") continue
                  for (var name of ["mediaMetadata", "mediaTitle", "mediaArtist"]) fits(findChild(card, name), name)
                  var art = findChild(card, "mediaArtwork")
                  if (artwork) { fits(art, "artwork"); compareReported(art.width, art.height) }
                  var title = findChild(card, "mediaTitle")
                  verifyReported(card.hasMedia, "active playback must retain content even without metadata")
                  compareReported(title.text, player.trackTitle || "Unknown track")
                  compareReported(title.textFormat, Text.PlainText)
                  compareReported(title.Accessible.name, title.text)
                  var artist = findChild(card, "mediaArtist")
                  compareReported(artist.Accessible.name, card.compactMetadata
                    ? player.trackArtist + (player.trackArtist ? " · " : "") + player.identity : player.trackArtist)
                  verifyReported(title.font.pixelSize >= 10)
                  verifyReported(findChild(card, "mediaArtist").font.pixelSize >= 10)
                  compareReported(title.scale, 1)
                  playbackFits(card, controls)
                  var timeline = findChild(card, "mediaSeekRow")
                  var transport = findChild(card, "mediaTransportRow")
                  if (stableRows === null) stableRows = { timelineY: timeline.y, transportY: transport.y }
                  compareReported(timeline.y, stableRows.timelineY, "timing changes must not move the timeline")
                  if (controls) compareReported(transport.y, stableRows.transportY, "timing changes must not move transport")
                  compareReported(card.durationAvailable, player.length > 0)
                  compareReported(card.positionAvailable, player.positionSupported)
                  compareReported(card.timelineAvailable, true)
                  compareReported(findChild(card, "mediaDurationTime").text, player.length > 0 ? "3:00" : "--:--")
                  compareReported(findChild(card, "mediaElapsedTime").text, player.positionSupported ? "0:55" : "--:--")
                }
              }
            }
          }
        }
      }
      function test_b_compact_controls_and_seek_work() {
        for (var width of [200, 500]) {
          configure(width, 100, true, true)
          card.players = [player]
          player.isPlaying = true; player.length = 180; player.position = 55
          player.positionSupported = true; player.canSeek = true; player.actions = ""
          player.trackTitle = "Fixture track"; player.trackArtist = "Fixture artist"
          wait(20)
          mouseClick(findChild(card, "mediaPreviousButton"))
          findChild(card, "mediaPlayPauseButton").forceActiveFocus()
          keyClick(Qt.Key_Space)
          findChild(card, "mediaNextButton").forceActiveFocus()
          keyClick(Qt.Key_Return)
          compareReported(player.actions, "previous;pause;next;")
          var seek = findChild(card, "mediaSeekArea")
          mouseClick(seek, seek.width * 0.75, seek.height / 2)
          verifyReported(Math.abs(player.position - 135) < 2)
          verifyReported(!card.seeking)
        }
      }
      function test_c_unsupported_seek_does_not_mutate_position() {
        configure(200, 100, true, true)
        player.length = 180; player.position = 55; player.positionSupported = true; player.canSeek = false
        card.players = [player]
        wait(20)
        playbackFits(card, true)
        var seek = findChild(card, "mediaSeekArea")
        verifyReported(!seek.enabled)
        mouseClick(seek, seek.width * 0.75, seek.height / 2)
        compareReported(player.position, 55)
        compareReported(card.seeking, false)
        compareReported(findChild(card, "mediaElapsedTime").text, "0:55")
        compareReported(findChild(card, "mediaDurationTime").text, "3:00")
      }
      function test_d_player_switch_resets_progress_and_drag() {
        configure(340, 0, true, true)
        player.length = 180; player.position = 55; player.positionSupported = true; player.canSeek = true
        card.players = [player]
        wait(20)
        card.previewSeek(0.9)
        compareReported(card.seeking, true)
        card.players = [unknownPlayer]
        wait(20)
        compareReported(card.seeking, false)
        compareReported(card.seekPreview, 0)
        compareReported(card.livePosition, 0)
        compareReported(card.progress, 0)
        card.commitSeek()
        compareReported(unknownPlayer.position, -1)
        compareReported(player.position, 55)
        playbackFits(card, true)
        compareReported(findChild(card, "mediaElapsedTime").text, "--:--")
        compareReported(findChild(card, "mediaDurationTime").text, "--:--")
        player.position = 12
        card.players = [player]
        wait(20)
        compareReported(card.livePosition, 12)
        compareReported(card.progress, 12 / 180)
        card.players = []
        wait(20)
        compareReported(card.livePosition, 0)
        compareReported(card.seeking, false)
        compareReported(card.timelineAvailable, false)
      }
      function test_e_track_change_cancels_drag() {
        configure(200, 100, true, true)
        player.trackTitle = "Old track"; player.trackArtist = "Fixture artist"
        player.isPlaying = true; player.length = 180; player.position = 55
        player.positionSupported = true; player.canSeek = true; card.players = [player]
        wait(20)
        var transport = findChild(card, "mediaTransportRow")
        var timeline = findChild(card, "mediaSeekRow")
        var transportY = transport.y
        var timelineY = timeline.y
        card.previewSeek(0.9)
        compareReported(card.seeking, true)
        player.trackTitle = ""; player.trackArtist = ""; player.trackAlbum = ""
        player.length = 0; player.position = -1; player.positionSupported = false
        wait(20)
        compareReported(card.seeking, false)
        compareReported(card.seekPreview, 0)
        compareReported(card.livePosition, 0)
        compareReported(card.progress, 0)
        card.commitSeek()
        compareReported(player.position, -1)
        playbackFits(card, true)
        compareReported(transport.y, transportY)
        compareReported(timeline.y, timelineY)
        compareReported(findChild(card, "mediaElapsedTime").text, "--:--")
        compareReported(findChild(card, "mediaDurationTime").text, "--:--")
        // Track changes must cancel a drag even when timing remains supported.
        player.trackTitle = "Recovered track"; player.trackArtist = "Fixture artist"
        player.length = 180; player.position = 12; player.positionSupported = true
        wait(20)
        card.previewSeek(0.75)
        compareReported(card.seeking, true)
        player.trackTitle = "Next track with the same duration"
        wait(20)
        compareReported(card.seeking, false)
        compareReported(card.seekPreview, 0)
        compareReported(card.livePosition, 12)
        card.commitSeek()
        compareReported(player.position, 12)
        playbackFits(card, true)
      }
      function test_z_capture() {
        if (!Quickshell.env("MEDIA_TEST_IMAGE")) return
        configure(340, 0, true, true)
        card.players = [player]; player.isPlaying = true; player.length = 180; player.position = 55
        player.positionSupported = true; player.canSeek = true
        player.trackTitle = "A very long <b>plain text</b> title that must elide in compact layouts"
        player.trackArtist = "An artist with a full name retained for accessibility"
        tall.visible = true; narrow.visible = true; wide.visible = true; noControls.visible = true; idle.visible = true
        unknownAuto.visible = true; unknownCompact.visible = true; noMetadataAuto.visible = true; noMetadataCompact.visible = true
        wait(50)
        for (var target of [card, tall, narrow, wide, noControls, unknownAuto, unknownCompact, noMetadataAuto, noMetadataCompact]) {
          playbackFits(target, target.showControls)
        }
        var saved = false
        preview.grabToImage(function(result) { saved = result.saveToFile(Quickshell.env("MEDIA_TEST_IMAGE")) })
        tryVerify(function() { return saved }, 2000)
      }
      function cleanup() {
        console.log(qtest_results.failed ? "MEDIA_RESIZING_FAIL" : "MEDIA_RESIZING_PASS", qtest_results.functionName)
      }
      function init() { assertionContext = qtest_results.functionName }
      function cleanupTestCase() {
        // qs does not install QtTest's normal text logger or propagate its
        // failures through the process exit code. Completion alone can pass a
        // failed suite, so export the actual assertion count explicitly.
        console.log("MEDIA_RESIZING_FAILURES", qtest_results.failCount)
        console.log("MEDIA_RESIZING_COMPLETE")
      }
    }
  }
}
`

test('real Qt media layout fits compact dimensions and keeps playback usable', { skip: !hasQt, timeout: 60000 }, () => {
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'omawidgets-media-resizing-'))
  try {
    fs.mkdirSync(path.join(stage, 'runtime'), { mode: 0o700 })
    for (const directory of ['Commons', 'Ui']) {
      fs.symlinkSync(path.join(shellDirectory, directory), path.join(stage, directory))
    }
    for (const filename of ['ArtworkPlaceholder.qml', 'WidgetConfig.js', 'WidgetTheme.js', 'WidgetSizing.js', 'SamplingModel.js']) {
      fs.copyFileSync(path.join(repository, filename), path.join(stage, filename))
    }
    const original = fs.readFileSync(path.join(repository, 'MediaWidget.qml'), 'utf8')
    const discovery = 'readonly property var players: Mpris.players ? Mpris.players.values : []'
    assert.ok(original.includes(discovery), 'update the isolated player injection after discovery changes')
    fs.writeFileSync(path.join(stage, 'MediaWidget.qml'), original.replace(discovery, 'property var players: []'))
    fs.writeFileSync(path.join(stage, 'shell.qml'), fixture)
    const result = spawnSync('qs', ['--no-color', '-p', path.join(stage, 'shell.qml')], {
      encoding: 'utf8', timeout: 50000, maxBuffer: 1024 * 1024,
      env: { ...process.env, XDG_RUNTIME_DIR: path.join(stage, 'runtime'), QT_QPA_PLATFORM: 'offscreen',
        QT_QPA_PLATFORMTHEME: 'basic', QT_QUICK_BACKEND: 'software' }
    })
    const output = result.stdout + result.stderr
    assert.equal(result.status, 0, output)
    assert.match(output, /MEDIA_RESIZING_COMPLETE/, output)
    assert.match(output, /MEDIA_RESIZING_FAILURES 0\b/, output)
    for (const name of ['a_auto_compact_and_states', 'b_compact_controls_and_seek_work',
      'c_unsupported_seek_does_not_mutate_position', 'd_player_switch_resets_progress_and_drag',
      'e_track_change_cancels_drag', 'z_capture']) {
      assert.match(output, new RegExp(`MEDIA_RESIZING_PASS test_${name}\\b`), output)
    }
    assert.doesNotMatch(output, /MEDIA_RESIZING_FAIL\b|FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop/)
  } finally {
    fs.rmSync(stage, { recursive: true, force: true })
  }
})
