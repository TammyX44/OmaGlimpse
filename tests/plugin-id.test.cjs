const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.resolve(__dirname, '..')
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8')
const id = 'io.github.tammyx44.omaglimpse'

test('manifest and shell entry points share the public plugin ID', () => {
  const manifest = JSON.parse(read('manifest.json'))
  assert.equal(manifest.id, id)
  assert.equal(manifest.name, 'OmaGlimpse')
  assert.equal(manifest.barWidget.displayName, 'OmaGlimpse Settings')
  assert.match(read('SettingsButton.qml'), new RegExp(`moduleName: "${id.replaceAll('.', '\\.')}"`))
  assert.match(read('SettingsButton.qml'), new RegExp(`"call", "${id.replaceAll('.', '\\.')}", "openSettings"`))
  assert.match(read('Widgets.qml'), new RegExp(`target: "${id.replaceAll('.', '\\.')}"`))
})

test('Wayland surfaces use the same plugin namespace', () => {
  assert.match(read('Widgets.qml'), new RegExp(`WlrLayershell\\.namespace: "${id.replaceAll('.', '\\.')}"`))
  assert.match(read('SettingsPanel.qml'), new RegExp(`WlrLayershell\\.namespace: "${id.replaceAll('.', '\\.')}\\.settings"`))
  assert.match(read('WidgetContextMenu.qml'), new RegExp(`WlrLayershell\\.namespace: "${id.replaceAll('.', '\\.')}\\.menu"`))
})

test('the previous plugin ID and name are not shipped in renamed files', () => {
  for (const name of ['manifest.json', 'SettingsButton.qml', 'Widgets.qml', 'SettingsPanel.qml', 'WidgetContextMenu.qml']) {
    assert.doesNotMatch(read(name), /io\.github\.tammyx44\.omawidgets|OmaWidgets/)
  }
})

test('the existing user settings file remains compatible', () => {
  assert.match(read('Widgets.qml'), /~\/\.config\/omarchy\/tammy-widgets\.json/)
  assert.match(read('WidgetConfig.js'), /\.config\/omarchy\/tammy-widgets\.json/)
})
