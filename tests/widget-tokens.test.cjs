const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.resolve(__dirname, '..')
const tokens = require('../lib/WidgetTokens.js')
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8')

test('type scale is ordered and keeps text readable', () => {
  const t = tokens.type
  assert.ok(t.caption >= 10 && t.label >= 10, 'no token drops below 10px')
  assert.ok(t.caption <= t.body && t.body <= t.title && t.title <= t.value && t.value <= t.lead)
  assert.ok(t.heroShort < t.heroCompact && t.heroCompact < t.hero)
  assert.ok(t.icon <= t.iconLarge)
})

test('spacing follows a 4/8 rhythm and header gaps use it', () => {
  const s = tokens.spacing
  for (const key of ['xs', 'sm', 'md', 'lg', 'xl']) assert.equal(s[key] % 4, 0, key)
  assert.deepEqual([s.xs, s.sm, s.md, s.lg, s.xl], [4, 8, 12, 16, 24])
  assert.equal(tokens.header.gap, s.sm)
  assert.equal(tokens.header.gapCompact, s.xs)
  assert.equal(tokens.list.rowGap, s.sm)
  assert.ok(tokens.padding.compact < tokens.padding.cardSmall && tokens.padding.cardSmall < tokens.padding.card)
})

test('weights are Qt 6 Font.Weight values', () => {
  assert.deepEqual(tokens.weight, { regular: 400, medium: 500, semibold: 600, bold: 700 })
})

test('emphasis levels match the WidgetTheme text resolvers', () => {
  global.Qt = { rgba: (r, g, b, a) => ({ r, g, b, a }) }
  try {
    const theme = require('../lib/WidgetTheme.js')
    const text = { r: 1, g: 1, b: 1 }
    assert.equal(theme.resolveSecondaryColor(text).a, tokens.emphasis.secondary)
    assert.equal(theme.resolveMutedColor(text).a, tokens.emphasis.muted)
    assert.equal(theme.resolveDimColor(text).a, tokens.emphasis.dim)
  } finally {
    delete global.Qt
  }
})

test('migrated cards take type, weight and radius from tokens', () => {
  const files = ['TopProcesses', 'DiskUsage', 'NetworkSpeed', 'Temperature', 'SystemMonitor', 'BatteryWidget',
    'MediaWidget', 'CircularGauge', 'GpuGauge', 'GpuPage', 'CompactToggle']
    .map(name => (['CircularGauge', 'CompactToggle'].includes(name) ? 'components/' : 'widgets/') + name + '.qml')
  for (const file of files) {
    const source = read(file)
    assert.match(source, /import "\.\.\/lib\/WidgetTokens\.js" as T/, file)
    assert.doesNotMatch(source, /font\.pixelSize: [0-9]/, file + ' hard-codes a font size')
    assert.doesNotMatch(source, /font\.bold|font\.weight: Font\./, file + ' hard-codes a weight')
    assert.doesNotMatch(source, /cardRadius: [0-9]/, file + ' hard-codes the card radius')
  }
})

test('list-card headers share one style', () => {
  for (const file of ['widgets/TopProcesses.qml', 'widgets/DiskUsage.qml']) {
    const source = read(file)
    assert.match(source, /font\.pixelSize: T\.type\.title\s+font\.weight: T\.weight\.bold\s+font\.letterSpacing: T\.tracking\.wide/, file)
  }
})
