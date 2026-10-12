const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')
global.Quickshell = { env: () => '/tmp/widgets-test' }
const Config = require('../WidgetConfig.js')
const source = fs.readFileSync(path.join(__dirname, '../Widgets.qml'), 'utf8')
function setup() {
  const root = { config: Config.defaultConfig(), configLoaded: false, pendingConfig: null,
    inFlightText: '', lastSavedText: '', externalText: '', externalConflict: false,
    persistenceBlocked: false, finalizing: false, suppressFileWatch: false, saveStatus: '',
    configError: '', updateLayoutIds() {}, widgetConfigRefresh() {}, beginMonitorSwitch() {} }
  const timer = { restart() {}, stop() {} }
  const writes = []
  const context = { root, Config, saveDebounceTimer: timer, saveWatchTimer: timer,
    configFile: { reload() {},
      setText(text) { writes.push(text); if (root.finalizing) finishWrite() },
      waitForJob() { if (root.inFlightText) finishWrite() } } }
  function finishWrite() {
    const start = source.indexOf('    onSaved: {') + '    onSaved: {'.length
    const end = source.indexOf('\n    }\n    onSaveFailed:', start)
    vm.runInContext(source.slice(start, end), context)
  }
  root.writes = writes
  root.finishWrite = finishWrite
  vm.createContext(context)
  for (const name of ['loadConfig', 'saveConfig', 'flushConfig', 'finishPendingSave', 'resolveConfigConflict']) {
    const start = source.indexOf(`  function ${name}(`)
    vm.runInContext(source.slice(start, source.indexOf('\n  }', start) + 4), context)
    root[name] = context[name]
  }
  return root
}
test('invalid disk data keeps last good settings and blocks persistence', () => {
  const root = setup()
  root.loadConfig('{"global":{"cardRadius":12}}')
  root.loadConfig('{broken')
  assert.equal(root.config.global.cardRadius, 12)
  assert.equal(root.persistenceBlocked, true)
  assert.match(root.configError, /Invalid/)
})
test('external edits while dirty require explicit resolution', () => {
  const root = setup()
  root.loadConfig('{}')
  root.config.global.cardRadius = 9
  root.saveConfig()
  root.loadConfig('{"global":{"cardRadius":4}}')
  assert.equal(root.externalConflict, true)
  assert.equal(root.config.global.cardRadius, 9)
  root.resolveConfigConflict(false)
  assert.equal(root.config.global.cardRadius, 4)
  assert.equal(root.pendingConfig, null)
})
test('own in-flight echo does not replace newer local changes', () => {
  const root = setup()
  root.loadConfig('{}')
  root.inFlightText = '{"global":{"cardRadius":4}}'
  root.config.global.cardRadius = 9
  root.saveConfig()
  root.loadConfig(root.inFlightText)
  assert.equal(root.config.global.cardRadius, 9)
  assert.equal(root.externalConflict, false)
})

test('unchanged startup save never waits for a FileView callback that will not happen', () => {
  const root = setup()
  const saved = JSON.stringify(Config.parseConfig(JSON.stringify(root.config)), null, 2) + '\n'
  root.loadConfig(saved)
  root.saveConfig()
  root.flushConfig()
  assert.equal(root.writes.length, 0)
  assert.equal(root.inFlightText, '')
  assert.equal(root.pendingConfig, null)
  assert.equal(root.saveStatus, 'Saved')
  root.config.widgets.media.x = 240
  root.config.widgets.media.cardHeight = 140
  root.saveConfig()
  root.flushConfig()
  assert.equal(root.writes.length, 1)
  assert.equal(JSON.parse(root.writes[0]).widgets.media.x, 240)
  root.finishWrite()
  assert.equal(root.inFlightText, '')
  const restarted = setup()
  restarted.loadConfig(root.lastSavedText)
  assert.equal(restarted.config.widgets.media.x, 240)
  assert.equal(restarted.config.widgets.media.cardHeight, 140)
})

test('normal saves remain asynchronous and preserve a newer pending edit', () => {
  const root = setup()
  root.loadConfig('{}')
  root.config.widgets.media.x = 200
  root.saveConfig()
  root.flushConfig()
  const first = root.inFlightText
  root.config.widgets.media.x = 300
  root.saveConfig()
  root.flushConfig()
  assert.equal(root.writes.length, 1)
  assert.equal(root.finalizing, false)
  root.finishWrite()
  assert.equal(root.lastSavedText, first)
  root.flushConfig()
  assert.equal(root.writes.length, 2)
  assert.equal(JSON.parse(root.writes[1]).widgets.media.x, 300)
})

test('teardown saves an edit still inside the debounce interval', () => {
  const root = setup()
  root.loadConfig('{}')
  root.config.widgets.systemMonitor.cardHeight = 170
  root.config.widgets.systemMonitor.x = 72
  root.saveConfig()
  root.finishPendingSave()
  assert.equal(root.inFlightText, '')
  assert.equal(root.pendingConfig, null)
  assert.equal(root.writes.length, 1)
  assert.equal(JSON.parse(root.lastSavedText).widgets.systemMonitor.x, 72)
  assert.equal(JSON.parse(root.lastSavedText).widgets.systemMonitor.cardHeight, 170)
})

test('teardown finishes an older write then saves the newest pending layout', () => {
  const root = setup()
  root.loadConfig('{}')
  root.config.widgets.media.x = 100
  root.saveConfig()
  root.flushConfig()
  root.config.widgets.media.x = 400
  root.saveConfig()
  root.finishPendingSave()
  assert.equal(root.inFlightText, '')
  assert.equal(root.pendingConfig, null)
  assert.equal(root.writes.length, 2)
  assert.equal(JSON.parse(root.lastSavedText).widgets.media.x, 400)
})

test('teardown never overwrites unreadable or conflicting disk settings', () => {
  for (const blocked of ['persistenceBlocked', 'externalConflict']) {
    const root = setup()
    root.loadConfig('{}')
    root.config.widgets.battery.x = 200
    root.saveConfig()
    root[blocked] = true
    root.finishPendingSave()
    assert.equal(root.writes.length, 0)
  }
  const unloaded = setup()
  unloaded.saveConfig()
  unloaded.finishPendingSave()
  assert.equal(unloaded.writes.length, 0)
})
