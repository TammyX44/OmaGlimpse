const { test } = require('node:test')
const assert = require('node:assert/strict')
global.Quickshell = { env: () => '/tmp/widgets-test' }
const Config = require('../WidgetConfig.js')

test('all seven cards default to Auto height, including legacy configs', () => {
  assert.equal(Config.allWidgetIds().length, 7)
  for (const cfg of [Config.defaultConfig(), Config.parseConfig(''), Config.parseConfig('{}'),
    Config.parseConfig('{"widgets":{"media":{"cardWidth":350}}}')]) {
    for (const id of Config.allWidgetIds()) assert.equal(cfg.widgets[id].cardHeight, 0, id)
  }
})

test('manual heights are rounded and bounded while invalid heights become Auto', () => {
  const cases = [
    [0, 0], ['0', 0], [80, 80], [1000, 1000], [1, 80], [-50, 80],
    [1001, 1000], [279.4, 279], [279.5, 280], [' 321.6 ', 322],
    [undefined, 0], [null, 0], ['', 0], ['  ', 0], ['bad', 0],
    ['Infinity', 0], [Infinity, 0], [-Infinity, 0], [NaN, 0],
    [true, 0], [false, 0], [[], 0], [[250], 0], [{}, 0]
  ]
  for (const [value, expected] of cases) {
    const widgets = Object.fromEntries(Config.allWidgetIds().map(id => [id, { cardHeight: value }]))
    const cfg = Config.parseConfig(JSON.stringify({ widgets }))
    for (const id of Config.allWidgetIds())
      assert.equal(cfg.widgets[id].cardHeight, expected, `${id}: ${String(value)}`)
  }
})

test('manual and Auto heights survive config serialization for every card', () => {
  const cfg = Config.defaultConfig()
  Config.allWidgetIds().forEach((id, index) => { cfg.widgets[id].cardHeight = index === 0 ? 0 : 80 + index * 140 })
  const restored = Config.parseConfig(JSON.stringify(cfg))
  for (const id of Config.allWidgetIds()) assert.equal(restored.widgets[id].cardHeight, cfg.widgets[id].cardHeight)
  assert.deepEqual(Config.parseConfig(JSON.stringify(restored)), restored)
})

test('height normalization preserves existing unrelated settings and stored layouts', () => {
  const saved = Config.defaultConfig()
  saved.widgets.media.cardHeight = 340.6
  saved.widgets.media.cardWidth = 420
  saved.widgets.media.showAlbumArt = false
  saved.widgets.media.customSetting = { retained: true }
  saved.widgets.systemMonitor.gpuDevice = '0000:03:00.0'
  saved.widgets.systemMonitor.gpuAliases = { '0000:03:00.0': 'Discrete' }
  saved.themeMode = 'custom'
  saved.colors.accent = '#abcdef'
  saved.global.cardSpacing = 20
  saved.editor.gridSize = 16
  saved.namedLayouts.Work = { widgets: { media: { x: 123 } }, cardSpacing: 8 }
  saved.monitorLayouts.docked = { widgets: { media: { cardHeight: 800 } }, cardSpacing: 12 }
  saved.monitorDisplays.docked = 'DP-1'
  saved.activeMonitorLayout = 'docked'
  saved.customSetting = { retained: true }
  const parsed = Config.parseConfig(JSON.stringify(saved))
  for (const key of ['themeMode', 'colors', 'global', 'editor', 'namedLayouts', 'monitorLayouts',
    'monitorDisplays', 'activeMonitorLayout', 'customSetting']) assert.deepEqual(parsed[key], saved[key], key)
  for (const key of ['cardWidth', 'showAlbumArt', 'customSetting'])
    assert.deepEqual(parsed.widgets.media[key], saved.widgets.media[key], key)
  assert.equal(parsed.widgets.systemMonitor.gpuDevice, saved.widgets.systemMonitor.gpuDevice)
  assert.deepEqual(parsed.widgets.systemMonitor.gpuAliases, saved.widgets.systemMonitor.gpuAliases)
  const baseline = structuredClone(saved)
  baseline.widgets.media.cardHeight = 0
  const withoutHeight = Config.parseConfig(JSON.stringify(baseline))
  assert.equal(parsed.widgets.media.cardHeight, 341)
  parsed.widgets.media.cardHeight = 0
  assert.deepEqual(parsed, withoutHeight)
  assert.deepEqual(saved.widgets.media.customSetting, { retained: true })
  assert.equal(saved.widgets.media.cardHeight, 340.6)
})
