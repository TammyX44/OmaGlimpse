const { test } = require('node:test')
const assert = require('node:assert/strict')
const model = require('../SamplingModel.js')

test('sampling intervals slow down, reject invalid values, and fit QML int', () => {
  assert.equal(model.interval(2000, 3), 6000)
  for (const multiplier of [0, -5, 0.5, NaN, Infinity, undefined])
    assert.equal(model.interval(2000, multiplier), 2000)
  assert.equal(model.interval(undefined, 3), 3000)
  assert.equal(model.interval(2000, Number.MAX_VALUE), 2147483647)
})
test('lock IPC accepts only an explicit boolean answer', () => {
  assert.equal(model.lockState('true\n'), true)
  assert.equal(model.lockState('false\n'), false)
  for (const value of ['', 'Target not found.', 'not ready', '0', 'TRUE'])
    assert.equal(model.lockState(value), null)
})
test('display sampling follows the requested output or any enabled output', () => {
  const raw = JSON.stringify([
    { name: 'eDP-1', dpmsStatus: false }, { name: 'DP-1', dpmsStatus: true }
  ])
  assert.equal(model.displayState(raw, ''), true)
  assert.equal(model.displayState(raw, 'eDP-1'), false)
  assert.equal(model.displayState(raw, 'DP-1'), true)
  assert.equal(model.displayState(raw, 'absent'), null)
  assert.equal(model.displayState('[{"dpmsStatus":true,"disabled":true}]', ''), false)
  assert.equal(model.displayState('[]', ''), false)
})
test('unknown DPMS data is never converted to a fabricated off state', () => {
  for (const raw of ['', 'bad json', '{}', '[null]', '[{}]', '[{"dpmsStatus":"false"}]'])
    assert.equal(model.displayState(raw, ''), null)
  assert.equal(model.displayState('[{}, {"dpmsStatus":true}]', ''), true)
  assert.equal(model.displayState('[{}, {"dpmsStatus":false}]', ''), null)
})
test('power profile mapping uses supplied enum constants, not assumed enum numbers', () => {
  assert.equal(model.profileName(17, 17, 23, 91), 'power-saver')
  assert.equal(model.profileName(23, 17, 23, 91), 'balanced')
  assert.equal(model.profileName(91, 17, 23, 91), 'performance')
  assert.equal(model.profileName(-1, 17, 23, 91), '')
})
