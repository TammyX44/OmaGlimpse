const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
global.Quickshell = { env: () => '/tmp/layout-transition-test' }
const Config = require('../WidgetConfig.js')
const Profiles = require('../LayoutProfiles.js')
const source = fs.readFileSync(require('node:path').join(__dirname, '../Widgets.qml'), 'utf8')

function setup() {
  const root = { config: Config.defaultConfig(), configLoaded: true, activeLayoutKey: 'large',
    currentLayoutKey: 'small', selectedDisplay: 'Laptop', outgoingLayoutSnapshot: null,
    undoStack: [], lastHistoryGroup: '', lastHistoryAt: 0, allEnabledIds: [],
    pendingConfig: null, inFlightText: '', lastSavedText: '', externalConflict: false,
    persistenceBlocked: false, dragInProgress: false,
    updateLayoutIds() {}, widgetConfigRefresh() {}, saveConfig() {} }
  Object.defineProperty(root, 'layoutSwitchPending', { get: () => root.activeLayoutKey !== root.currentLayoutKey })
  const timer = { restart() {}, stop() {} }
  const context = { root, Config, Profiles, monitorSwitchTimer: timer, relayoutTimer: timer,
    shallowClone: obj => ({ ...obj }) }
  vm.createContext(context)
  for (const name of ['beginMonitorSwitch', 'recordLayoutChange', 'updateWidgetConfig', 'loadConfig']) {
    const start = source.indexOf(`  function ${name}(`)
    vm.runInContext(source.slice(start, source.indexOf('\n  }', start) + 4), context)
    root[name] = context[name]
  }
  const start = source.indexOf('onTriggered: {', source.indexOf('id: monitorSwitchTimer')) + 'onTriggered: {'.length
  const end = source.indexOf('\n    }\n  }\n\n  function selectDisplay', start)
  context.finishSwitch = () => vm.runInContext(`(function(){${source.slice(start, end)}})()`, context)
  return { root, context }
}

test('monitor transition freezes layout edits and preserves the outgoing arrangement', () => {
  const { root, context } = setup()
  root.config.widgets.battery.x = 1600
  const incoming = Profiles.snapshot(root.config)
  incoming.widgets.battery.x = 600
  root.config.monitorLayouts.small = incoming
  root.beginMonitorSwitch()
  root.updateWidgetConfig('battery', 'x', 700)
  assert.equal(root.config.widgets.battery.x, 1600)
  root.updateWidgetConfig('battery', 'cardHeight', 400)
  assert.equal(root.config.widgets.battery.cardHeight, 0)
  root.updateWidgetConfig('battery', 'showPower', false)
  context.finishSwitch()
  assert.equal(root.config.monitorLayouts.large.widgets.battery.x, 1600)
  assert.equal(root.config.widgets.battery.x, 600)
  assert.equal(root.config.widgets.battery.showPower, false)
  assert.equal(root.layoutSwitchPending, false)
  root.updateWidgetConfig('battery', 'x', 700)
  assert.equal(root.config.widgets.battery.x, 700)
})

test('a cancelled hotplug transition retains its original layout and drops its snapshot', () => {
  const { root, context } = setup()
  root.config.widgets.battery.x = 1600
  root.beginMonitorSwitch()
  root.currentLayoutKey = 'large'
  root.beginMonitorSwitch()
  context.finishSwitch()
  assert.equal(root.config.widgets.battery.x, 1600)
  assert.equal(root.outgoingLayoutSnapshot, null)
})

test('accepting external settings clears stale undo; invalid settings preserve it', () => {
  const { root } = setup()
  root.currentLayoutKey = 'large'
  root.undoStack = [Profiles.snapshot(root.config)]
  root.lastHistoryGroup = 'battery:position'
  root.loadConfig('{"widgets":{"battery":{"x":900}}}')
  assert.equal(root.undoStack.length, 0)
  assert.equal(root.lastHistoryGroup, '')
  assert.equal(root.config.widgets.battery.x, 900)
  root.undoStack = [Profiles.snapshot(root.config)]
  root.loadConfig('{invalid')
  assert.equal(root.undoStack.length, 1)
  assert.equal(root.config.widgets.battery.x, 900)
})

test('cancel, edit, and restart before the timer captures the accepted edit', () => {
  const { root, context } = setup()
  root.config.widgets.battery.x = 1600
  root.beginMonitorSwitch()
  root.currentLayoutKey = 'large'
  root.beginMonitorSwitch()
  assert.equal(root.outgoingLayoutSnapshot, null)
  root.updateWidgetConfig('battery', 'x', 1700)
  root.currentLayoutKey = 'small'
  root.beginMonitorSwitch()
  context.finishSwitch()
  assert.equal(root.config.monitorLayouts.large.widgets.battery.x, 1700)
})
