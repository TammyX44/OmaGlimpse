const { test } = require('node:test')
const assert = require('node:assert/strict')
global.Quickshell = { env: () => '/tmp/widgets-test' }
const config = require('../WidgetConfig.js')
const theme = require('../WidgetTheme.js')

test('battery power defaults on and explicit false survives', () => {
  assert.equal(config.defaultConfig().widgets.battery.showPower, true)
  assert.equal(config.parseConfig('{"widgets":{"battery":{"showPower":false}}}').widgets.battery.showPower, false)
  assert.equal(config.defaultConfig().widgets.battery.gaugeDiameter, 94)
  assert.equal(config.defaultConfig().widgets.temperature.unit, 'celsius')
  assert.equal(config.parseConfig('{"widgets":{"temperature":{"unit":"fahrenheit"}}}').widgets.temperature.unit, 'fahrenheit')
  assert.equal(config.parseConfig('{"widgets":{"temperature":{"unit":"kelvin"}}}').widgets.temperature.unit, 'celsius')
})
test('legacy global keys migrate before default merge', () => {
  assert.equal(config.parseConfig('{"blurIntensity":80}').global.blurIntensity, 80)
  assert.equal(config.parseConfig('{"blurIntensity":80,"global":{"blurIntensity":30}}').global.blurIntensity, 30)
  assert.equal(config.parseConfig('{"blurEnabled":false,"cardRadius":0}').global.blurEnabled, false)
  assert.equal(config.parseConfig('{"cardRadius":0}').global.cardRadius, 0)
})
test('parse result rejects malformed configuration rather than replacing it', () => {
  for (const raw of ['{', '[]', 'null', '{"global":[]}', '{"widgets":{"battery":false}}'])
    assert.equal(config.parseConfigResult(raw).ok, false, raw)
})
test('normalizes numbers and strips prototype keys without polluting objects', () => {
  const cfg = config.parseConfig('{"__proto__":{"polluted":true},"widgets":{"battery":{"cardWidth":-50,"gaugeDiameter":900,"refreshInterval":1,"showPower":"false"}}}')
  assert.equal(cfg.widgets.battery.cardWidth, 200)
  assert.equal(cfg.widgets.battery.gaugeDiameter, 100)
  assert.equal(cfg.widgets.battery.refreshInterval, 500)
  assert.equal(cfg.widgets.battery.showPower, true)
  assert.equal(Object.hasOwn(cfg, '__proto__'), false)
  assert.equal({}.polluted, undefined)
})
test('custom colors accept only supported six/eight digit hex values', () => {
  assert.equal(theme.normalizeHex('#7aa2f7'), '#7aa2f7')
  assert.equal(theme.normalizeHex('  #7AA2F7cc  '), '#7AA2F7cc')
  for (const value of ['', '#fff', '#12345', '#123456789', 'red', null, undefined])
    assert.equal(theme.normalizeHex(value), '', String(value))
})
