const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

// Focused interaction coverage; the shared sizing suite owns the all-card matrix.
test('list cards keep a readable row and support scrolling, focus, and resize recovery', {
  skip: !process.env.LIST_CARD_QML_TESTS,
}, () => {
  const repo = path.resolve(__dirname, '..')
  const shell = process.env.OMARCHY_SHELL_DIR || '/usr/share/omarchy/shell'
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'omawidgets-list-cards-'))
  try {
    fs.mkdirSync(path.join(stage, 'runtime'), { mode: 0o700 })
    for (const dir of ['Commons', 'Ui']) fs.symlinkSync(path.join(shell, dir), path.join(stage, dir))
    for (const file of ['TopProcesses.qml', 'DiskUsage.qml', 'ProcessModel.js', 'WidgetModel.js',
      'WidgetConfig.js', 'SamplingModel.js', 'WidgetSizing.js'])
      fs.symlinkSync(path.join(repo, file), path.join(stage, file))
    fs.writeFileSync(path.join(stage, 'shell.qml'), `
import QtQuick
import QtTest
import Quickshell
import "." as Plugin

ShellRoot {
  id: root
  property bool ready: false
  Timer { interval: 300; running: true; onTriggered: root.ready = true }
  FloatingWindow {
    visible: true
    implicitWidth: 680
    implicitHeight: 620
    Item {
      id: preview
      anchors.fill: parent
      Plugin.TopProcesses { id: processes; x: 10; y: 10; samplingEnabled: false }
      Plugin.DiskUsage { id: disk; x: 340; y: 10; samplingEnabled: false }
    }
    TestCase {
      name: "ListCardResizing"
      when: root.ready
      function configure(card, height) {
        var widgets = {}
        widgets[card.widgetId] = { cardWidth: 300, cardHeight: height }
        card.config = { widgets: widgets }
        wait(30)
      }
      function seed() {
        processes.hasLoaded = true
        processes.errorMessage = ""
        processes.processes = Array.from({length: 15}, function(_, i) {
          return { name: "worker " + i, cpu: i, mem: i / 10 }
        })
        disk.hasLoaded = true
        disk.errorMessage = ""
        disk.disks = Array.from({length: 8}, function(_, i) {
          return { mount: "/volume" + i, used: "18G", size: "128G", avail: "110G", percent: 14 }
        })
        wait(30)
      }
      function test_scroll_and_resize() {
        seed()
        for (var card of [processes, disk]) {
          configure(card, 0)
          var natural = card.naturalCardHeight
          var viewport = findChild(card, "listCardViewport")
          compare(card.height, natural)
          compare(viewport.contentHeight, viewport.height)
          configure(card, 80)
          compare(card.height, card.minimumCardHeight)
          compare(card.naturalCardHeight, natural)
          var rows = viewport.contentItem.children[0].children
          var firstRow = null
          for (var child of rows) {
            if (child.modelData !== undefined && child.index === 0) firstRow = child
          }
          verify(firstRow !== null)
          verify(viewport.height >= firstRow.height, "one complete readable row")
          verify(viewport.clip)
          verify(viewport.contentHeight > viewport.height)
          var group = findChild(card, "widgetSizingContent")
          var origin = card.mapFromItem(group, 0, 0)
          verify(origin.y >= 0 && origin.y + group.height <= card.height)
          viewport.forceActiveFocus()
          tryCompare(viewport, "activeFocus", true)
          compare(findChild(card, "listCardFocus").visible, true)
          keyClick(Qt.Key_End)
          compare(viewport.contentY, viewport.contentHeight - viewport.height)
          keyClick(Qt.Key_PageUp)
          verify(viewport.contentY < viewport.contentHeight - viewport.height)
          keyClick(Qt.Key_Home)
          compare(viewport.contentY, 0)
          keyClick(Qt.Key_Down)
          verify(viewport.contentY > 0)
          keyClick(Qt.Key_Up)
          compare(viewport.contentY, 0)
          mouseWheel(viewport, viewport.width / 2, viewport.height / 2, 0, -120)
          tryVerify(function() { return viewport.contentY > 0 })
          keyClick(Qt.Key_End)
          configure(card, 1000)
          compare(viewport.contentY, 0)
          compare(card.naturalCardHeight, natural)
          configure(card, 0)
          compare(card.height, natural)
          compare(viewport.contentY, 0)
        }
      }
      function test_wrapped_error_and_shrinking_model() {
        seed()
        for (var card of [processes, disk]) {
          configure(card, 80)
          var viewport = findChild(card, "listCardViewport")
          var manual = card.height
          card.errorMessage = "Unable to read data: " + "very_long_unbroken_error_path/".repeat(80)
          wait(30)
          compare(card.height, manual)
          verify(viewport.contentHeight > 1000)
          var natural = card.naturalCardHeight
          viewport.forceActiveFocus()
          keyClick(Qt.Key_End)
          compare(viewport.contentY, viewport.contentHeight - viewport.height)
          configure(card, 300)
          compare(card.naturalCardHeight, natural)
          compare(card.height, 300)
          card.errorMessage = ""
          if (card === processes) card.processes = []
          else card.disks = []
          wait(30)
          compare(viewport.contentY, 0)
          verify(viewport.contentHeight <= viewport.height)
          configure(card, 0)
          compare(card.height, card.naturalCardHeight)
        }
      }
      function test_z_preview() {
        if (!Quickshell.env("LIST_CARD_TEST_IMAGE")) return
        seed()
        configure(processes, 100)
        configure(disk, 80)
        var saved = false
        preview.grabToImage(function(result) { saved = result.saveToFile(Quickshell.env("LIST_CARD_TEST_IMAGE")) })
        tryVerify(function() { return saved }, 2000)
      }
      function cleanupTestCase() {
        console.log("LIST_CARD_QML_COMPLETE")
        Qt.callLater(function() { Qt.quit() })
      }
    }
  }
}
`)
    const result = spawnSync('qs', ['--no-color', '-p', path.join(stage, 'shell.qml')], {
      encoding: 'utf8', timeout: 25000,
      env: { ...process.env, XDG_RUNTIME_DIR: path.join(stage, 'runtime'), QT_QPA_PLATFORM: 'offscreen',
        QT_QPA_PLATFORMTHEME: 'basic', QT_QUICK_BACKEND: 'software' },
    })
    const output = result.stdout + result.stderr
    assert.equal(result.status, 0, output)
    assert.match(output, /LIST_CARD_QML_COMPLETE/, output)
    assert.doesNotMatch(output, /FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop/, output)
  } finally {
    fs.rmSync(stage, { recursive: true, force: true })
  }
})
