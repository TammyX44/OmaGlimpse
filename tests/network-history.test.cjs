const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const history = require('../NetworkHistory.js')

test('scale rises immediately for either channel and decays by elapsed time', () => {
  assert.equal(history.nextScale(65536, 1000000, 2000000, 1000), 2400000)
  const fallen = history.nextScale(2400000, 0, 0, 1000)
  assert.ok(fallen < 2400000 && fallen > 2200000)
  assert.ok(Math.abs(history.nextScale(fallen, 0, 0, 14000) - 2400000 / Math.E) < 1e-6)
  assert.equal(history.nextScale(2400000, 0, 0, 600000), history.minimumScale)
  assert.equal(history.nextScale(Infinity, NaN, -1, NaN), history.minimumScale)
})

test('fixed MB/s reference has a safe five MB/s default', () => {
  for (const value of [undefined, NaN, Infinity, 0, -1, ''])
    assert.equal(history.fixedScale(value), 5 * 1024 * 1024)
  assert.equal(history.fixedScale(0.5), 524288)
})

test('history is immutable, time bounded, count bounded and replaces duplicate timestamps', () => {
  let samples = []
  for (let i = 0; i < 200; i++) samples = history.append(samples, i * 100, i, i, false)
  assert.equal(samples.length, history.maxSamples)
  const previous = samples
  samples = history.append(samples, 19900, NaN, -1, true)
  assert.equal(samples.length, 120)
  assert.equal(previous.at(-1).gap, false)
  assert.deepEqual(samples.at(-1), { time: 19900, rx: 0, tx: 0, gap: true })
  assert.equal(history.append(samples, 100000, 0, 0, false).length, 1)
})

test('graph uses real timestamps and breaks at marked gaps and delayed polls', () => {
  const p = (time, gap = false) => ({ time, rx: 50, tx: 200, gap })
  const points = [p(0), p(1000), p(2000, true), p(3000), p(4000), p(10000), p(11000)]
  const lines = history.segments(points, 'rx', 60000, 120, 40, 100, 2500)
  assert.equal(lines.length, 3)
  assert.deepEqual(lines[0], [{ x: 0, y: 20 }, { x: 120 * (1 - 59000 / 60000), y: 20 }])
  assert.equal(history.segments(points, 'tx', 60000, 120, 40, 100, 2500)[0][0].y, 0)
  assert.deepEqual(history.segments(points, 'rx', 120000, 120, 40, 100, 2500), [])
})

test('network widget runtime: sampling lifecycle, gaps, scale, and narrow fit', { skip: !process.env.NETWORK_QML_TESTS }, () => {
  const repo = path.resolve(__dirname, '..')
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'omawidgets-network-'))
  try {
    for (const name of fs.readdirSync(repo).filter(name => /\.(qml|js)$/.test(name)))
      fs.symlinkSync(path.join(repo, name), path.join(stage, name))
    const shellDir = process.env.OMARCHY_SHELL_DIR || '/usr/share/omarchy/shell'
    for (const name of ['Commons', 'Ui']) fs.symlinkSync(path.join(shellDir, name), path.join(stage, name))
    fs.mkdirSync(path.join(stage, 'runtime'), { mode: 0o700 })
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
    implicitWidth: 320; implicitHeight: 400
    Plugin.NetworkSpeed {
      id: card
      samplingEnabled: false
      config: ({widgets: {networkSpeed: {interface: "test0", refreshInterval: 1000, cardWidth: 180}}})
    }
    TestCase {
      name: "NetworkRuntime"
      when: root.ready
      property int passes: 0
      property int failures: 0
      function raw(iface, rx, tx) { return iface + ": " + rx + " 0 0 0 0 0 0 0 " + tx }
      function init() {
        card.samplingEnabled = false
        card.samplingMultiplier = 1
        card.config = {widgets: {networkSpeed: {interface: "test0", refreshInterval: 1000, cardWidth: 180}}}
        card.samplingEnabled = true
        card.resetBaseline()
      }
      function cleanup() {
        card.samplingEnabled = false
        if (qtest_results.failed) {
          failures++
          console.error("NETWORK_RUNTIME_FAILED " + qtest_results.functionName)
        } else passes++
      }
      function test_sampling() {
        card.updateNet(raw("test0", 100, 50), 10000)
        compare(card.sampleReady, false)
        card.updateNet(raw("test0", 1048676, 524338), 11000)
        compare(card.rxSpeed, 1048576)
        compare(card.history.length, 1)
        verify(card.scaleBytes >= card.rxSpeed)
        compare(findChild(card, "networkSampleTimer").running, true)
        card.samplingEnabled = false
        compare(findChild(card, "networkSampleTimer").running, false)
        compare(card.history.length, 0)
        compare(card.prevTime, 0)
        card.updateNet(raw("test0", 9000000, 9000000), 20000)
        compare(card.prevTime, 0)
        card.samplingEnabled = true
        card.updateNet(raw("test0", 9000000, 9000000), 20000)
        compare(card.sampleReady, false)
        card.visible = false
        compare(findChild(card, "networkSampleTimer").running, false)
        compare(card.prevTime, 0)
        card.visible = true
        card.samplingMultiplier = 3
        compare(findChild(card, "networkSampleTimer").interval, 3000)
        compare(card.prevTime, 0)
      }
      function test_gaps_and_interface() {
        card.updateNet(raw("test0", 100, 50), 10000)
        card.updateNet(raw("test0", 200, 100), 11000)
        card.updateNet(raw("test0", 0, 0), 12000)
        compare(card.sampleReady, false)
        compare(card.history[1].gap, true)
        card.updateNet(raw("test0", 100, 50), 13000)
        compare(card.sampleReady, true)
        card.updateNet(raw("test0", 10000, 5000), 30000)
        compare(card.sampleReady, false)
        compare(card.history[3].gap, true)
        card.updateNet(raw("test1", 100, 50), 31000)
        compare(card.sampleState, "Unavailable")
        compare(card.history.length, 0)
        card.config = {widgets: {networkSpeed: {interface: "test1", refreshInterval: 1000}}}
        card.updateNet(raw("test1", 100, 50), 32000)
        compare(card.activeInterface, "test1")
        compare(card.sampleReady, false)
      }
      function test_fixed_and_fit() {
        var graph = findChild(card, "networkHistoryGraph")
        verify(graph.visible)
        verify(graph.width <= card.width - 40)
        verify(card.effectiveGaugeDiameter * 2 + 8 <= card.width - 40)
        var height = card.height
        card.config = {widgets: {networkSpeed: {interface: "test0", scaleMode: "fixed", scaleLimitMbps: 5, showHistory: false, cardWidth: 180}}}
        compare(card.scaleBytes, 5242880)
        compare(graph.visible, false)
        card.samplingEnabled = false
        tryVerify(function() { return card.height < height }, 1000)
        card.samplingEnabled = true
        card.resetBaseline()
        card.updateNet(raw("test0", 0, 0), 10000)
        card.updateNet(raw("test0", 10485760, 0), 11000)
        compare(card.rxSpeed, 10485760)
        compare(findChild(card, "networkDownloadGauge").value, 100)
      }
      function cleanupTestCase() { console.log("NETWORK_RUNTIME_TOTAL " + passes + " passed, " + failures + " failed") }
    }
  }
}
`)
    const result = spawnSync('qs', ['--no-color', '-p', path.join(stage, 'shell.qml')], {
      env: { ...process.env, XDG_RUNTIME_DIR: path.join(stage, 'runtime'), QT_QPA_PLATFORM: 'offscreen', QT_QPA_PLATFORMTHEME: 'basic', QT_QUICK_BACKEND: 'software' },
      encoding: 'utf8', timeout: 20000
    })
    const output = result.stdout + result.stderr
    assert.equal(result.status, 0, output)
    assert.match(output, /NETWORK_RUNTIME_TOTAL 3 passed, 0 failed/)
    assert.doesNotMatch(output, /NETWORK_RUNTIME_FAILED|FAIL!|ReferenceError|TypeError|Failed to load configuration|Unable to assign|Binding loop/)
  } finally {
    fs.rmSync(stage, { recursive: true, force: true })
  }
})
