const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.resolve(__dirname, '..')
const media = fs.readFileSync(path.join(root, 'MediaWidget.qml'), 'utf8')
const placeholder = fs.readFileSync(path.join(root, 'ArtworkPlaceholder.qml'), 'utf8')

test('the media card shows theme-matched fallback artwork only without a ready cover', () => {
  assert.match(media, /ArtworkPlaceholder\s*\{[\s\S]*?accentColor: root\.accentColor[\s\S]*?textColor: root\.textColor[\s\S]*?visible: !artImage\.visible/)
  assert.match(media, /source: root\.artworkSource/)
})

test('fallback artwork follows the parent theme and adds no external asset', () => {
  assert.match(placeholder, /property color accentColor:/)
  assert.match(placeholder, /property color textColor:/)
  assert.match(placeholder, /color: root\.accentColor/)
  assert.doesNotMatch(placeholder, /\b(?:Image|AnimatedImage|ShaderEffectSource)\s*\{/)
})
