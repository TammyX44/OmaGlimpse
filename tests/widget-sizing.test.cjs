const { test } = require('node:test')
const assert = require('node:assert/strict')
const Sizing = require('../WidgetSizing.js')

test('Auto height preserves the natural card footprint', () => {
  for (const natural of [110, 180, 237.5, 640]) {
    for (const requested of [0, undefined, null, '', NaN, Infinity, false, true, {}])
      assert.equal(Sizing.cardHeight(requested, natural), natural)
  }
})

test('manual height enlarges independently and refuses to crop dynamic content', () => {
  assert.equal(Sizing.cardHeight(360, 180), 360)
  assert.equal(Sizing.cardHeight(80, 180), 180)
  assert.equal(Sizing.cardHeight(360, 420), 420)
  assert.equal(Sizing.cardHeight(360, 180), 360)
  assert.equal(Sizing.cardHeight(360.6, 180), 361)
  assert.equal(Sizing.cardHeight(5000, 180), 1000)
  assert.equal(Sizing.cardHeight(-1, 40), 80)
  assert.equal(Sizing.cardHeight(1000, 1400), 1400)
})

test('adaptive cards can shrink below the full layout without ignoring their compact floor', () => {
  assert.equal(Sizing.cardHeight(100, 180, 100), 100)
  assert.equal(Sizing.cardHeight(80, 180, 100), 100)
  assert.equal(Sizing.cardHeight(0, 180, 100), 180)
  assert.equal(Sizing.cardHeight(120, 640, 80), 120)
  assert.equal(Sizing.cardHeight(1000, 1400, 80), 1000)
})
