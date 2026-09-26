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
    persistenceBlocked: false, configError: '', updateLayoutIds() {}, widgetConfigRefresh() {} }
  const timer = { restart() {}, stop() {} }
  const context = { root, Config, saveDebounceTimer: timer, configFile: { reload() {} } }
  vm.createContext(context)
  for (const name of ['loadConfig', 'saveConfig', 'resolveConfigConflict']) {
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
