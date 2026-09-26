const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const source = fs.readFileSync(require('node:path').join(__dirname, '../Widgets.qml'), 'utf8')
const start = source.indexOf('  function applyPreset(')
const end = source.indexOf('\n  // IPC handler', start)
const code = source.slice(start, end)

for (const preset of ['left', 'right', 'center', 'top', 'bottom', 'spread']) {
  for (let count = 0; count <= 7; count++) {
    test(`${preset} positions all ${count} enabled cards`, () => {
      const ids = Array.from({ length: count }, (_, i) => `w${i}`)
      const root = {
        config: { widgets: Object.fromEntries(ids.map(id => [id, { x: -99, y: -99 }])) },
        allEnabledIds: ids, width: 1536, height: 864, barOffset: 26,
        edgeMargin: 24, dockOffset: 60, cardSpacing: 12,
        updateLayoutIds() {}, widgetConfigRefresh() {}, saveConfig() {}
      }
      const context = { root, shallowClone: x => ({ ...x }), cardHeightFor: () => 100,
        cardWidthFor: () => 220, relayoutTimer: { restart() {} } }
      vm.createContext(context)
      vm.runInContext(code, context)
      context.applyPreset(preset)
      for (const id of ids) {
        const p = root.config.widgets[id]
        if (preset === 'spread') assert.deepEqual([p.x, p.y], [-1, -1])
        else {
          assert.ok(p.x >= 0 && p.x + 220 <= root.width, `${id}: x=${p.x}`)
          assert.ok(p.y >= 26 && p.y + 100 <= root.height, `${id}: y=${p.y}`)
        }
      }
    })
  }
}
