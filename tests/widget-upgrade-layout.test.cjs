const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Layout = require('../WidgetLayout.js')
global.Quickshell = { env: () => '/tmp/widgets-test' }
const Config = require('../WidgetConfig.js')

function monitor(overrides = {}) {
  return { widgetId: 'systemMonitor', x: 40, y: 44, width: 391,
    height: 224 + 1 / 3, manual: true, ...overrides }
}
function media(overrides = {}) {
  return { widgetId: 'media', x: 66, y: 264, width: 314, height: 180,
    manual: true, ...overrides }
}

test('legacy GPU stack gains clearance without changing horizontal placement or inputs', () => {
  const rects = [monitor(), media()]
  const before = structuredClone(rects)
  assert.deepEqual(Layout.repairGpuStack(rects, 10, 804), {
    moves: [{ widgetId: 'media', y: 279 }], blocked: false
  })
  assert.deepEqual(rects, before)
})

test('a moved card clears space for the rest of its saved stack', () => {
  const below = media({ widgetId: 'topProcesses', y: 454, height: 100 })
  assert.deepEqual(Layout.repairGpuStack([below, media(), monitor()], 10, 804), {
    moves: [{ widgetId: 'media', y: 279 }, { widgetId: 'topProcesses', y: 469 }], blocked: false
  })
})

test('clear, separate-column, and above-monitor cards retain their positions', () => {
  for (const card of [media({ y: 279 }), media({ x: 441 }), media({ y: 20 })]) {
    assert.deepEqual(Layout.repairGpuStack([monitor(), card], 10, 804), { moves: [], blocked: false })
  }
})

test('unrelated overlapping cards are not rearranged', () => {
  const a = media({ x: 600, y: 350 })
  const b = media({ widgetId: 'battery', x: 610, y: 360 })
  assert.deepEqual(Layout.repairGpuStack([monitor(), a, b], 10, 804), { moves: [], blocked: false })
})

test('auto-positioned cards remain fixed and are avoided by moved manual cards', () => {
  const auto = media({ widgetId: 'battery', y: 280, height: 100, manual: false })
  assert.deepEqual(Layout.repairGpuStack([media(), auto, monitor()], 10, 804), {
    moves: [{ widgetId: 'media', y: 390 }], blocked: false
  })
  assert.deepEqual(Layout.repairGpuStack([monitor(), media({ manual: false })], 10, 804), {
    moves: [], blocked: false
  })
})

test('a card is not pushed beyond the usable screen area', () => {
  assert.deepEqual(Layout.repairGpuStack([monitor(), media()], 10, 450), {
    moves: [], blocked: true
  })
})

test('zero spacing allows adjoining borders and repaired layouts need no further moves', () => {
  const result = Layout.repairGpuStack([monitor({ height: 224 }), media()], 0, 804)
  assert.deepEqual(result, { moves: [{ widgetId: 'media', y: 268 }], blocked: false })
  assert.deepEqual(Layout.repairGpuStack([monitor({ height: 224 }), media({ y: 268 })], 0, 804), {
    moves: [], blocked: false
  })
})

test('a disabled system monitor does not change the layout', () => {
  assert.deepEqual(Layout.repairGpuStack([media()], 10, 804), { moves: [], blocked: false })
})

test('fresh settings are current while older saved settings migrate once', () => {
  assert.equal(Config.defaultConfig().gpuLayoutRevision, 1)
  assert.equal(Config.parseConfig('').gpuLayoutRevision, 1)
  const legacy = Config.parseConfig('{"widgets":{"media":{"x":66,"y":264}}}')
  assert.equal(legacy.gpuLayoutRevision, 0)
  assert.equal(legacy.widgets.media.y, 264)
  legacy.gpuLayoutRevision = 1
  assert.equal(Config.parseConfig(JSON.stringify(legacy)).gpuLayoutRevision, 1)
})

const source = fs.readFileSync(path.join(__dirname, '../Widgets.qml'), 'utf8')
const start = source.indexOf('  function repairGpuUpgradeLayout(')
const code = source.slice(start, source.indexOf('\n  }', start) + 4)
function setup() {
  const config = Config.parseConfig('{"widgets":{"systemMonitor":{"x":40,"y":44},"media":{"x":66,"y":264}}}')
  const root = {
    config, configLoaded: true, editMode: false, dragInProgress: false,
    pendingConfig: null, inFlightText: '', persistenceBlocked: false, externalConflict: false,
    allEnabledIds: ['systemMonitor', 'media'], manualLayoutIds: ['systemMonitor', 'media'],
    cardSpacing: 10, height: 864, dockOffset: 60, saves: 0,
    cardItemFor: () => ({ contentReady: true, hasSettled: true }),
    getAllCardRects: () => [monitor(), media()], shallowClone: x => ({ ...x }),
    widgetConfigRefresh() {}, saveConfig() { this.saves++ }
  }
  const context = { root, Config, Layout, relayoutTimer: { restart() {} } }
  vm.createContext(context)
  vm.runInContext(code, context)
  root.repairGpuUpgradeLayout = context.repairGpuUpgradeLayout
  return root
}

test('migration persists a revision once and preserves other settings', () => {
  const root = setup()
  const before = structuredClone(root.config)
  root.repairGpuUpgradeLayout()
  before.gpuLayoutRevision = 1
  before.widgets.media.y = 279
  assert.deepEqual(root.config, before)
  assert.equal(root.saves, 1)
  root.repairGpuUpgradeLayout()
  assert.equal(root.saves, 1)
})

test('migration waits for ready geometry and never interrupts edits or unsaved/conflicting data', () => {
  const guards = {
    configLoaded: false, editMode: true, dragInProgress: true, pendingConfig: {},
    inFlightText: '{}', persistenceBlocked: true, externalConflict: true,
    cardItemFor: () => null
  }
  for (const [key, value] of Object.entries(guards)) {
    const root = setup()
    const original = root.config
    root[key] = value
    root.repairGpuUpgradeLayout()
    assert.equal(root.config, original, key)
    assert.equal(root.saves, 0, key)
  }
  for (const card of [{ contentReady: false, hasSettled: true }, { contentReady: true, hasSettled: false }]) {
    const root = setup()
    root.cardItemFor = () => card
    root.repairGpuUpgradeLayout()
    assert.equal(root.saves, 0)
  }
})

test('hidden GPU mode records the revision without moving cards', () => {
  const root = setup()
  root.config.widgets.systemMonitor.showGpu = false
  root.repairGpuUpgradeLayout()
  assert.equal(root.config.widgets.media.y, 264)
  assert.equal(root.config.gpuLayoutRevision, 1)
})
