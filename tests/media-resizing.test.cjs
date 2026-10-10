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
import "." as Plugin

ShellRoot {
  id: suite
  property bool ready: false
  Timer { interval: 150; running: true; onTriggered: suite.ready = true }
  QtObject {
    id: player
    property string dbusName: "org.mpris.MediaPlayer2.fixture"
    property string desktopEntry: "fixture"
    property string identity: "Fixture player with a long accessible name"
    property string trackTitle: "A very long <b>plain text</b> title that must elide in compact layouts"
    property string trackArtist: "An artist with a full name retained for accessibility"
    property string trackAlbum: "Fixture album"
    property string trackArtUrl: ""
    property bool isPlaying: true
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
  FloatingWindow {
    visible: true
    implicitWidth: 780; implicitHeight: 530
    color: "#151821"
    Item {
      id: preview
      width: 780; height: 530
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
        id: idle; x: 240; y: 450; samplingEnabled: false; visible: false
        config: ({widgets:{media:{cardWidth:280,cardHeight:80,showControls:false}}})
      }
    }
    TestCase {
      name: "MediaResizing"
      when: suite.ready
      function configure(width, height, controls, artwork) {
        card.config = {widgets:{media:{cardWidth:width,cardHeight:height,showControls:controls,showAlbumArt:artwork}}}
      }
      function fits(item, label) {
        verify(item !== null, label + ": missing")
        var point = card.mapFromItem(item, 0, 0)
        verify(point.x >= -0.1 && point.x + item.width <= card.width + 0.1, label + ": horizontal")
        verify(point.y >= -0.1 && point.y + item.height <= card.height + 0.1, label + ": vertical")
      }
      function test_a_auto_compact_and_states() {
        for (var controls of [true, false]) {
          for (var artwork of [true, false]) {
            for (var width of [200, 330, 340, 359, 360, 500]) {
              for (var height of [0, 80, 100, 110, 120, 122, 139, 140, 160, 179, 180, 220, 259, 260, 360, 400, 1000]) {
                configure(width, height, controls, artwork)
                for (var state of ["idle", "playing", "paused", "unknown duration"]) {
                  player.isPlaying = state === "playing"
                  player.length = state === "unknown duration" ? 0 : 180
                  card.players = state === "idle" ? [] : [player]
                  wait(1)
                  var natural = controls ? 180 : 122
                  compare(card.naturalCardHeight, natural)
                  compare(card.height, height === 0 ? natural : Math.max(controls ? 100 : 80, height))
                  fits(findChild(card, "widgetSizingContent"), "content")
                  if (state === "idle") continue
                  for (var name of ["mediaMetadata", "mediaTitle", "mediaArtist"]) fits(findChild(card, name), name)
                  var art = findChild(card, "mediaArtwork")
                  if (artwork) { fits(art, "artwork"); compare(art.width, art.height) }
                  var title = findChild(card, "mediaTitle")
                  compare(title.text, player.trackTitle)
                  compare(title.textFormat, Text.PlainText)
                  compare(title.Accessible.name, player.trackTitle)
                  var artist = findChild(card, "mediaArtist")
                  compare(artist.Accessible.name, card.compactMetadata
                    ? player.trackArtist + " · " + player.identity : player.trackArtist)
                  verify(title.font.pixelSize >= 10)
                  verify(findChild(card, "mediaArtist").font.pixelSize >= 10)
                  compare(title.scale, 1)
                  var transport = findChild(card, "mediaTransportRow")
                  compare(transport.visible, controls)
                  if (controls) {
                    for (var name of ["mediaPreviousButton", "mediaPlayPauseButton", "mediaNextButton"]) {
                      var button = findChild(card, name)
                      fits(button, name)
                      verify(button.enabled && button.width >= 28 && button.height >= 28)
                      compare(button.scale, 1)
                    }
                  }
                  var seek = findChild(card, "mediaSeekArea")
                  compare(seek.visible, state !== "unknown duration")
                  if (seek.visible) {
                    fits(seek, "seek hit area")
                    fits(findChild(card, "mediaElapsedTime"), "elapsed time")
                    fits(findChild(card, "mediaDurationTime"), "duration time")
                    verify(seek.height >= 24 && seek.width >= 80)
                  }
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
          player.isPlaying = true; player.length = 180; player.actions = ""
          wait(20)
          mouseClick(findChild(card, "mediaPreviousButton"))
          findChild(card, "mediaPlayPauseButton").forceActiveFocus()
          keyClick(Qt.Key_Space)
          findChild(card, "mediaNextButton").forceActiveFocus()
          keyClick(Qt.Key_Return)
          compare(player.actions, "previous;pause;next;")
          var seek = findChild(card, "mediaSeekArea")
          mouseClick(seek, seek.width * 0.75, seek.height / 2)
          verify(Math.abs(player.position - 135) < 2)
          verify(!card.seeking)
        }
      }
      function test_z_capture() {
        if (!Quickshell.env("MEDIA_TEST_IMAGE")) return
        configure(340, 0, true, true)
        card.players = [player]; player.isPlaying = true; player.length = 180
        tall.visible = true; narrow.visible = true; wide.visible = true; noControls.visible = true; idle.visible = true
        wait(50)
        var saved = false
        preview.grabToImage(function(result) { saved = result.saveToFile(Quickshell.env("MEDIA_TEST_IMAGE")) })
        tryVerify(function() { return saved }, 2000)
      }
      function cleanupTestCase() { console.log("MEDIA_RESIZING_COMPLETE") }
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
    assert.doesNotMatch(output, /FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop/)
  } finally {
    fs.rmSync(stage, { recursive: true, force: true })
  }
})
