const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const source = fs.readFileSync(path.join(__dirname, '../MediaWidget.qml'), 'utf8')

function extractFunction(name) {
  const start = source.indexOf(`  function ${name}(`)
  assert.notEqual(start, -1, `missing ${name}`)
  const bodyStart = source.indexOf('{', start)
  let depth = 0

  for (let i = bodyStart; i < source.length; i++) {
    if (source[i] === '{') depth += 1
    else if (source[i] === '}') {
      depth -= 1
      if (depth === 0) return source.slice(start, i + 1)
    }
  }

  throw new Error(`unterminated ${name}`)
}

const context = {}
vm.createContext(context)
vm.runInContext([
  extractFunction('canRunAction'),
  extractFunction('runAction'),
  extractFunction('playerKey'),
  extractFunction('refreshArtwork')
].join('\n'), context)

function fakePlayer(overrides = {}) {
  const calls = []
  return {
    calls,
    isPlaying: false,
    canPlay: false,
    canPause: false,
    canTogglePlaying: false,
    canGoNext: false,
    canGoPrevious: false,
    play() { calls.push('play') },
    pause() { calls.push('pause') },
    togglePlaying() { calls.push('togglePlaying') },
    next() { calls.push('next') },
    previous() { calls.push('previous') },
    ...overrides
  }
}

function usePlayer(activePlayer, otherPlayers = []) {
  context.root = {
    activePlayer,
    players: [activePlayer, ...otherPlayers],
    canRunAction: context.canRunAction
  }
}

test('previous and next target only the displayed active player', () => {
  const displayed = fakePlayer({ canGoPrevious: true, canGoNext: true })
  const other = fakePlayer({ canGoPrevious: true, canGoNext: true })
  usePlayer(displayed, [other])

  assert.equal(context.runAction('previous'), true)
  assert.equal(context.runAction('next'), true)
  assert.deepEqual(displayed.calls, ['previous', 'next'])
  assert.deepEqual(other.calls, [])
})

test('play/pause uses the displayed player state and strongest capability', () => {
  const paused = fakePlayer({ canPlay: true, canTogglePlaying: true })
  usePlayer(paused)
  assert.equal(context.runAction('playPause'), true)
  assert.deepEqual(paused.calls, ['play'])

  const playing = fakePlayer({ isPlaying: true, canPause: true, canTogglePlaying: true })
  usePlayer(playing)
  assert.equal(context.runAction('playPause'), true)
  assert.deepEqual(playing.calls, ['pause'])
})

test('togglePlaying is an exact-player fallback only when explicitly supported', () => {
  const toggleOnly = fakePlayer({ canTogglePlaying: true })
  usePlayer(toggleOnly)
  assert.equal(context.runAction('playPause'), true)
  assert.deepEqual(toggleOnly.calls, ['togglePlaying'])

  const unsupported = fakePlayer()
  usePlayer(unsupported)
  assert.equal(context.runAction('playPause'), false)
  assert.equal(context.runAction('next'), false)
  assert.equal(context.runAction('previous'), false)
  assert.deepEqual(unsupported.calls, [])
})

test('media controls contain no global transport fallback', () => {
  assert.doesNotMatch(source, /quickshell.*\bmedia\b.*(?:playPause|next|previous)/)
  assert.doesNotMatch(source, /media(?:PlayPause|Next|Prev)Proc/)
  assert.match(source, /var player = root\.activePlayer/)
})

test('transport controls expose keyboard and accessibility affordances', () => {
  assert.equal((source.match(/Accessible\.role: Accessible\.Button/g) || []).length, 3)
  assert.equal((source.match(/activeFocusOnTab: enabled/g) || []).length, 3)
  assert.equal((source.match(/Keys\.onReturnPressed:/g) || []).length, 3)
  assert.equal((source.match(/Keys\.onEnterPressed:/g) || []).length, 3)
  assert.equal((source.match(/Keys\.onSpacePressed:/g) || []).length, 3)
  assert.match(source, /Accessible\.name: "Previous track"/)
  assert.match(source, /Accessible\.name: root\.isPlaying \? "Pause" : "Play"/)
  assert.match(source, /Accessible\.name: "Next track"/)
})

test('seek still assigns position on the displayed active player', () => {
  assert.match(source, /root\.activePlayer\.position = newPos/)
})

test('remote artwork is never assigned directly to Image.source', () => {
  assert.match(source, /source: root\.artworkSource/)
  assert.doesNotMatch(source, /source: root\.artUrl/)
  assert.match(source, /root\.artworkSource = ""/)
  assert.match(source, /requestKey === root\.artworkRequestKey/)
  assert.match(source, /command: \["python3", helper, url\]/)
})

test('track change cancels the old fetch and clears its image before starting the next', () => {
  let destroyed = false
  const old = { running: true, destroy() { destroyed = true } }
  let created
  context.root = {
    artworkProcess: old,
    artworkSource: 'file:///old.png',
    showAlbumArt: true,
    hasMedia: true,
    artUrl: 'https://example.test/new.png',
    artworkRequestKey: 'new'
  }
  context.Qt = { resolvedUrl: () => 'file:///tmp/fetch_album_art.py' }
  context.artworkProcessComponent = {
    createObject(_root, options) { created = { ...options, running: false }; return created }
  }
  context.refreshArtwork.call(context.root)
  assert.equal(old.running, false)
  assert.equal(destroyed, true)
  assert.equal(context.root.artworkSource, '')
  assert.equal(context.root.artworkProcess, created)
  assert.equal(created.running, true)
  assert.equal(created.requestKey, 'new')
  assert.deepEqual(Array.from(created.command), ['python3', '/tmp/fetch_album_art.py', 'https://example.test/new.png'])
})

test('an absent MPRIS player has a stable empty artwork key', () => {
  assert.equal(context.playerKey(null), '')
  assert.equal(context.playerKey(undefined), '')
  assert.equal(context.playerKey({ identity: 'Player' }), 'Player')
  assert.equal(context.playerKey({ dbusName: 'org.mpris.MediaPlayer2.demo' }), 'org.mpris.MediaPlayer2.demo')
})

function layoutExpression(marker, property, indent) {
  const start = source.indexOf(marker)
  assert.notEqual(start, -1, `missing ${marker}`)
  const expression = source.slice(start).match(new RegExp(
    `^ {${indent}}${property}: ([^\\n]+(?:\\n {${indent + 2},}[^\\n]+)*)`, 'm'))
  assert.ok(expression, `missing ${property} after ${marker}`)
  return expression[1]
}

// Evaluate the actual QML bindings with reactive getters and a cycle guard.
// This catches height -> row -> natural-height loops without duplicating the
// layout formulas in a second implementation.
const compiledExpressions = new Map()
function mediaLayout(showControls = true, showAlbumArt = true) {
  const layout = {
    root: { showControls, showAlbumArt, width: 340, hasMedia: false, trackLength: 0, widgetCfg: { cardHeight: 0 } },
    Sizing: require('../WidgetSizing.js'),
    content: { anchors: {} }, trackInfo: {}, seekRow: {}, transportRow: {}, artBox: {}, metadata: {}
  }
  const reading = new Set()
  const names = Object.keys(layout).concat('parent', 'self')
  function evaluate(expression, parent, self) {
    if (!compiledExpressions.has(expression)) {
      compiledExpressions.set(expression, new Function(...names, `with (self || {}) { return (${expression}) }`))
    }
    return compiledExpressions.get(expression)(...Object.values(layout), parent, self)
  }
  function binding(target, property, expression, parent) {
    Object.defineProperty(target, property, {
      get() {
        const key = `${Object.keys(layout).find(k => layout[k] === target) || 'anchors'}.${property}`
        assert.ok(!reading.has(key), `binding loop: ${[...reading, key].join(' -> ')}`)
        reading.add(key)
        try { return evaluate(expression, parent, target) }
        finally { reading.delete(key) }
      }
    })
  }
  const sizingSection = source.slice(source.indexOf('  readonly property real naturalCardHeight:'), source.indexOf('// ── Player selection'))
  for (const match of sizingSection.matchAll(/^  readonly property (?:real|bool) (\w+): ([^\n]+(?:\n {4,}[^\n]+)*)/gm)) {
    binding(layout.root, match[1], match[2])
  }
  binding(layout.root, 'height', layoutExpression('id: root', 'height', 2))
  binding(layout.content, 'width', 'root.width - 2 * root.contentMargin')
  binding(layout.content, 'height', layoutExpression('id: content', 'height', 4))
  binding(layout.content.anchors, 'topMargin', layoutExpression('id: content', 'anchors.topMargin', 4))
  Object.defineProperty(layout.content, 'implicitHeight', {
    get() { throw new Error('card height must not read content.implicitHeight') }
  })
  for (const id of ['trackInfo', 'seekRow', 'transportRow']) {
    for (const property of ['height', 'visible']) {
      binding(layout[id], property, layoutExpression(`id: ${id}`, property, 6), layout.content)
    }
  }
  binding(layout.trackInfo, 'width', layoutExpression('id: trackInfo', 'width', 6), layout.content)
  binding(layout.seekRow, 'width', layoutExpression('id: seekRow', 'width', 6), layout.content)
  binding(layout.transportRow, 'width', '3 * root.transportButtonSize + 2 * root.transportSpacing')
  for (const id of ['seekRow', 'transportRow']) {
    binding(layout[id], 'y', layoutExpression(`id: ${id}`, 'y', 6), layout.content)
  }
  binding(layout.transportRow, 'x', layoutExpression('id: transportRow', 'x', 6), layout.content)
  for (const id of ['artBox', 'metadata']) {
    for (const property of ['x', 'y', 'width', 'height']) {
      binding(layout[id], property, layoutExpression(`id: ${id}`, property, 8), layout.trackInfo)
    }
  }
  return { ...layout, evaluate }
}

const mediaStates = [
  { name: 'idle', hasMedia: false, trackLength: 0, isPlaying: false },
  { name: 'metadata without duration', hasMedia: true, trackLength: 0, isPlaying: false },
  { name: 'playing seekable track', hasMedia: true, trackLength: 180, isPlaying: true },
  { name: 'paused seekable track', hasMedia: true, trackLength: 180, isPlaying: false },
  { name: 'stopped', hasMedia: false, trackLength: 0, isPlaying: false }
]

for (const showControls of [true, false]) {
  for (const showAlbumArt of [true, false]) {
    test(`Auto preserves the original footprint across states (controls ${showControls}, artwork ${showAlbumArt})`, () => {
      const layout = mediaLayout(showControls, showAlbumArt)
      const { root } = layout
      const originalHeight = showControls ? 180 : 122
      for (const width of [200, 340, 500]) {
        root.width = width
        for (const state of mediaStates) {
          Object.assign(root, state)
          assert.equal(root.naturalCardHeight, originalHeight, state.name)
          assert.equal(root.height, originalHeight, state.name)
          assert.equal(root.compactLayout, false)
          assert.equal(root.transportButtonSize, 44)
          assert.equal(layout.trackInfo.height, 64)
          assert.equal(layout.content.anchors.topMargin, 16)
          assert.equal(layout.artBox.width, showAlbumArt ? 64 : 0)
        }
      }
    })

    test(`manual height fits real content without cycles (controls ${showControls}, artwork ${showAlbumArt})`, () => {
      const layout = mediaLayout(showControls, showAlbumArt)
      const { root, content, trackInfo, seekRow, transportRow, artBox, metadata } = layout
      const natural = root.naturalCardHeight
      for (const width of [200, 279, 280, 330, 340, 359, 360, 500]) {
        root.width = width
        for (const requested of [80, 100, 110, 120, 122, 139, 140, 150, 160, 179, 180, 220, 240, 259, 260, 360, 400, 1000]) {
          root.widgetCfg.cardHeight = requested
          const expected = Math.max(showControls ? 100 : 80, requested)
          const neighborY = 257 + expected + 12
          for (const state of mediaStates) {
            Object.assign(root, state)
            const label = `${width}x${requested}, ${state.name}`
            assert.equal(root.height, expected, label)
            assert.equal(root.naturalCardHeight, natural, `${label}: Auto changed`)
            assert.ok(257 + root.height + 12 <= neighborY, `${label}: overlaps neighbor`)
            const contentY = content.anchors.topMargin
            assert.ok(contentY >= 0 && contentY + content.height <= root.height, `${label}: content exceeds card`)
            if (!state.hasMedia) {
              const placeholderHeight = layout.evaluate(layoutExpression('// --- Placeholder when no media ---', 'height', 6))
              assert.equal(placeholderHeight + 2 * contentY, root.height, label)
              continue
            }
            assert.ok(metadata.width >= 90, `${label}: metadata too narrow`)
            assert.ok(metadata.x >= 0 && metadata.x + metadata.width <= content.width, label)
            assert.ok(metadata.y >= 0 && metadata.y + metadata.height <= trackInfo.height, `${label}: metadata exceeds track row`)
            assert.equal(artBox.height, artBox.width, `${label}: distorted art`)
            assert.ok(artBox.x >= 0 && artBox.x + artBox.width <= content.width, label)
            assert.ok(artBox.y >= 0 && artBox.y + artBox.height <= trackInfo.height, label)
            if (seekRow.visible) {
              assert.ok(contentY + seekRow.y + seekRow.height <= root.height, `${label}: seek clipped`)
              assert.ok(seekRow.width * 0.56 - 12 >= 80, `${label}: seek track too narrow`)
            }
            assert.equal(transportRow.visible, showControls, `${label}: controls silently hidden`)
            if (showControls) {
              assert.ok(root.transportButtonSize >= 28, label)
              assert.ok(transportRow.x >= 0 && transportRow.x + transportRow.width <= content.width, label)
              assert.ok(transportRow.y >= 0 && contentY + transportRow.y + transportRow.height <= root.height, `${label}: transport clipped`)
              if (root.inlineControls) {
                assert.ok(metadata.x + metadata.width + root.layoutSpacing <= transportRow.x, `${label}: transport overlaps metadata`)
              } else {
                assert.ok(transportRow.y >= trackInfo.height, `${label}: transport overlaps metadata`)
                if (seekRow.visible) assert.ok(transportRow.y >= seekRow.y + seekRow.height, `${label}: transport overlaps seek`)
              }
            }
          }
        }
      }
      root.widgetCfg.cardHeight = 0
      assert.equal(root.height, natural, 'reset to Auto restores the original footprint')
    })
  }
}

test('natural height is independent of resolved dimensions and compressed children', () => {
  const layout = mediaLayout()
  const expression = source.match(/^  readonly property real naturalCardHeight: ([^\n]+(?:\n {4,}[^\n]+)*)/m)[1]
  assert.doesNotMatch(expression, /\b(?:height|width|content|trackInfo|seekRow|transportRow|compactLayout)\b/)
  assert.equal(layout.root.naturalCardHeight, 180)
  layout.root.widgetCfg.cardHeight = 100
  assert.equal(layout.root.height, 100)
  assert.equal(layout.root.naturalCardHeight, 180)
})

test('compact layout uses geometry, readable elided metadata, and full accessibility names', () => {
  assert.match(source, /fillMode: Image\.PreserveAspectCrop/)
  assert.doesNotMatch(source, /\b(?:scale|transform|fontSizeMode):/)
  assert.doesNotMatch(source, /font\.pixelSize: (?:[0-9](?!\d)|root\.[^\n]*\? [0-9] :)/)
  assert.match(source, /Accessible\.name: root\.title/)
  assert.match(source, /Accessible\.name: root\.identity/)
  assert.match(source, /root\.artist \+ \(root\.artist && root\.identity \? " · " : ""\) \+ root\.identity/)
  assert.equal((source.match(/elide: Text\.ElideRight/g) || []).length, 5)
  assert.match(source, /height: Math\.max\(24, parent\.height\)/)
  for (const id of ['previousButton', 'playPauseButton', 'nextButton']) {
    assert.equal(layoutExpression(`id: ${id}`, 'width', 8), 'root.transportButtonSize')
    assert.equal(layoutExpression(`id: ${id}`, 'height', 8), 'width')
  }
  const wide = mediaLayout()
  wide.root.width = 500
  wide.root.widgetCfg.cardHeight = 100
  assert.equal(wide.root.inlineControls, true)
  assert.equal(wide.root.height, 100)
  const tall = mediaLayout()
  tall.root.width = 200
  tall.root.widgetCfg.cardHeight = 360
  assert.equal(tall.root.stackedArtwork, true)
  assert.equal(tall.artBox.width, 168)
  assert.equal(tall.metadata.width, 168)
})
