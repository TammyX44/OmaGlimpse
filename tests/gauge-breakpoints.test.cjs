const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

// Run with GAUGE_QML_TESTS=1; isolated real Qt geometry, no image capture.
test('Battery and Network gauge breakpoints preserve monotonic rings and Auto footprints in Qt', {
  skip: !process.env.GAUGE_QML_TESTS,
}, () => {
  const repo = path.resolve(__dirname, '..')
  const shell = process.env.OMARCHY_SHELL_DIR || '/usr/share/omarchy/shell'
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'omawidgets-gauge-breakpoints-'))
  try {
    fs.mkdirSync(path.join(stage, 'runtime'), { mode: 0o700 })
    for (const dir of ['Commons', 'Ui']) fs.symlinkSync(path.join(shell, dir), path.join(stage, dir))
    for (const file of ['BatteryWidget.qml', 'NetworkSpeed.qml', 'CircularGauge.qml',
      'WidgetConfig.js', 'WidgetTheme.js', 'WidgetModel.js', 'SamplingModel.js',
      'WidgetSizing.js', 'NetworkHistory.js'])
      fs.symlinkSync(path.join(repo, file), path.join(stage, file))
    fs.writeFileSync(path.join(stage, 'shell.qml'), `
import QtQuick
import QtTest
import Quickshell
import "." as Plugin
ShellRoot {
  id: root
  property bool ready: false
  Timer { interval: 200; running: true; onTriggered: root.ready = true }
  FloatingWindow {
    visible: true
    implicitWidth: 1100; implicitHeight: 1050
    Plugin.BatteryWidget { id: battery; samplingEnabled: false }
    Plugin.NetworkSpeed { id: network; x: 550; samplingEnabled: false }
    TestCase {
      name: "GaugeBreakpoints"
      when: root.ready
      property int passes: 0
      property int failures: 0
      function cleanup() {
        if (qtest_results.failed) failures++
        else passes++
      }
      // Quickshell does not print QtTest's normal assertion log.
      function verify(condition, message) {
        if (!condition) { console.error("FAIL! " + message); fail(message || "verification failed") }
      }
      function compare(actual, expected) {
        if (actual !== expected) {
          console.error("FAIL! actual=" + actual + " expected=" + expected)
          fail("comparison failed")
        }
      }
      function configure(card, width, height, preferred, history) {
        var widgets = {}
        widgets[card.widgetId] = {cardWidth:width,cardHeight:height,gaugeDiameter:preferred,showHistory:history}
        card.config = {widgets:widgets}
        // Positioners defer their geometry until polish. forceLayout makes
        // this deterministic even outside the native qmltestrunner (qs owns
        // Quickshell's statically registered imports).
        layout(card)
      }
      function layout(item) {
        for (var child of item.children) layout(child)
        if (typeof item.forceLayout === "function") item.forceLayout()
      }
      function fits(card) {
        var content = findChild(card, "widgetSizingContent")
        var p = card.mapFromItem(content, 0, 0)
        verify(p.x >= -0.01 && p.x + content.width <= card.width + 0.01, "content width")
        verify(p.y >= -0.01 && p.y + content.height <= card.height + 0.01,
          card.widgetId + " content=" + content.height + " card=" + card.height)
        compare(card.scale, 1)
      }
      function matrix(card, history) {
        for (var width of [200,330,500]) {
          for (var preferred of [40,60,94,120,180]) {
            configure(card, width, 0, preferred, history)
            var natural = card.naturalCardHeight
            compare(card.height, natural)
            // Auto keeps the existing full layout and its original padding.
            var content = findChild(card, "widgetSizingContent")
            verify(Math.abs(natural - content.height - (card === battery ? 32 : 40)) < 0.01,
              card.widgetId + " Auto footprint=" + natural + " content=" + content.height)
            var boundary = Math.ceil(natural)
            var heights = [80,90,100,120,159,160,161,199,200,201,259,260,261,
              boundary - 1,boundary,boundary + 1,400,600]
            heights.sort(function(a,b) { return a-b })
            var previous = 0
            for (var height of heights) {
              if (height < 80) continue
              configure(card, width, height, preferred, history)
              compare(card.width, width)
              compare(card.height, Math.max(height,card.minimumCardHeight))
              compare(card.naturalCardHeight, natural)
              verify(card.effectiveGaugeDiameter + 0.01 >= previous,
                card.widgetId + " shrank at " + width + "x" + height + " preferred=" + preferred
                + " from=" + previous + " to=" + card.effectiveGaugeDiameter)
              verify(card.effectiveGaugeDiameter <= preferred, "preferred diameter cap")
              previous = card.effectiveGaugeDiameter
              fits(card)
            }
            configure(card, width, 0, preferred, history)
            compare(card.height, natural)
          }
        }
      }
      function test_battery_profiles_errors_and_breakpoints() {
        for (var profiles of [[],["power-saver","balanced","performance"]]) {
          battery.profiles = profiles
          for (var error of ["","Profile change not confirmed by hardware: please retry the selected profile."]) {
            battery.profileError = error
            matrix(battery, false)
            configure(battery, 200, 80, 180, false)
            var summary = findChild(battery, "batteryStatusSummary")
            compare(summary.text, battery.compactSummary)
            verify(summary.visible && summary.width >= 80)
            compare(findChild(battery, "batteryProfileControls").visible, profiles.length > 0)
            compare(findChild(battery, "batteryCompactProfileError").visible, error !== "")
            if (error) compare(findChild(battery, "batteryCompactProfileError").text, error)
            fits(battery)
          }
        }
        battery.profiles = ["power-saver","balanced","performance"]
        battery.profileError = ""
        configure(battery, 330, 199, 180, false)
        var before = battery.effectiveGaugeDiameter
        configure(battery, 330, 200, 180, false)
        console.log("GAUGE_EDGE battery 330 preferred=180 heights=199/200 rings="
          + before + "/" + battery.effectiveGaugeDiameter)
      }
      function test_network_history_status_and_numeric_transition() {
        for (var history of [false,true]) {
          matrix(network, history)
          for (var width of [200,330,500]) {
            configure(network, width, 159, 180, history)
            compare(network.compactNumbers, true)
            var before = network.effectiveGaugeDiameter
            configure(network, width, 160, 180, history)
            compare(network.compactNumbers, false)
            verify(network.effectiveGaugeDiameter >= before)
            var ring = findChild(network, "networkDownloadGauge")
            compare(ring.diameter, network.effectiveGaugeDiameter)
            verify(ring.diameter * 0.24 >= 13, "numeric-to-ring text remains readable")
            fits(network)
          }
          for (var state of ["Paused","Unavailable","Measuring…"]) {
            network.sampleReady = false
            network.sampleState = state
            configure(network, 200, 90, 120, history)
            verify(findChild(network, "networkInterfaceHeader").text.indexOf(state) !== -1)
            compare(findChild(network, "networkHistoryGraph").visible, history)
            fits(network)
          }
          network.sampleReady = true
          network.activeInterface = "demo0"
          network.rxSpeed = 1250000; network.txSpeed = 180000
          matrix(network, history)
        }
        configure(network, 330, 159, 180, true)
        var numeric = network.effectiveGaugeDiameter
        configure(network, 330, 160, 180, true)
        console.log("GAUGE_EDGE network 330 preferred=180 heights=159/160 rings="
          + numeric + "/" + network.effectiveGaugeDiameter)
        configure(network, 330, 259, 180, true)
        var compact = network.effectiveGaugeDiameter
        configure(network, 330, 260, 180, true)
        console.log("GAUGE_EDGE network 330 preferred=180 heights=259/260 rings="
          + compact + "/" + network.effectiveGaugeDiameter)
      }
      function cleanupTestCase() {
        console.log("GAUGE_BREAKPOINT_QML_COMPLETE " + passes + " passed, " + failures + " failed")
        Qt.callLater(function() { Qt.quit() })
      }
    }
  }
}
`)
    const result = spawnSync('qs', ['--no-color', '-p', path.join(stage, 'shell.qml')], {
      encoding: 'utf8', timeout: 40000,
      env: { ...process.env, XDG_RUNTIME_DIR: path.join(stage, 'runtime'),
        QT_QPA_PLATFORM: 'offscreen', QT_QPA_PLATFORMTHEME: 'basic', QT_QUICK_BACKEND: 'software' },
    })
    const output = result.stdout + result.stderr
    assert.equal(result.status, 0, output)
    assert.match(output, /GAUGE_BREAKPOINT_QML_COMPLETE/, output)
    assert.match(output, /GAUGE_BREAKPOINT_QML_COMPLETE 2 passed, 0 failed/, output)
    assert.doesNotMatch(output, /FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop/, output)
    for (const line of output.split('\n').filter(line => /GAUGE_EDGE|Totals:/.test(line))) console.log(line)
  } finally {
    fs.rmSync(stage, { recursive: true, force: true })
  }
})
