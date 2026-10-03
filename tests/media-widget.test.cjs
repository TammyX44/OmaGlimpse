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

for (const showControls of [true, false]) {
  test(`media state changes preserve space above a neighbor (controls ${showControls ? 'shown' : 'hidden'})`, () => {
    const layout = {
      root: { showControls, hasMedia: false, trackLength: 0, isPlaying: false },
      content: { anchors: {} },
      trackInfo: {}, seekRow: {}, transportRow: {}
    }
    vm.createContext(layout)
    const evaluate = expression => vm.runInContext(`(${expression})`, layout)
    for (const id of ['trackInfo', 'seekRow', 'transportRow']) {
      layout[id].height = evaluate(layoutExpression(`id: ${id}`, 'height', 6))
    }
    layout.content.spacing = evaluate(layoutExpression('id: content', 'spacing', 4))
    layout.content.anchors.topMargin = evaluate(layoutExpression('id: content', 'anchors.topMargin', 4))
    // The placeholder fills the reserved card. Depending on its resulting
    // implicit height here would introduce a recursive size binding.
    Object.defineProperty(layout.content, 'implicitHeight', {
      get() { throw new Error('media card height depends on changing content.implicitHeight') }
    })
    const heightExpression = layoutExpression('id: root', 'height', 2)
    Object.defineProperty(layout.root, 'height', { get: () => evaluate(heightExpression) })

    const mediaY = 257
    const gap = 12
    const idleHeight = layout.root.height
    const neighborY = mediaY + idleHeight + gap
    assert.equal(idleHeight, showControls ? 180 : 122)

    for (const state of [
      { name: 'idle', hasMedia: false, trackLength: 0, isPlaying: false },
      { name: 'metadata without duration', hasMedia: true, trackLength: 0, isPlaying: false },
      { name: 'playing seekable track', hasMedia: true, trackLength: 180, isPlaying: true },
      { name: 'paused seekable track', hasMedia: true, trackLength: 180, isPlaying: false },
      { name: 'stopped', hasMedia: false, trackLength: 0, isPlaying: false }
    ]) {
      Object.assign(layout.root, state)
      const height = layout.root.height
      assert.equal(height, idleHeight, state.name)
      assert.ok(mediaY + height + gap <= neighborY, `${state.name}: media overlaps its neighbor`)

      const visibleRows = ['trackInfo', 'seekRow', 'transportRow'].filter(id =>
        evaluate(layoutExpression(`id: ${id}`, 'visible', 6)))
      const contentHeight = visibleRows.reduce((sum, id) => sum + layout[id].height, 0)
        + Math.max(0, visibleRows.length - 1) * layout.content.spacing
      assert.ok(contentHeight + 24 <= height, `${state.name}: media content exceeds its reserved card`)

      if (!state.hasMedia) {
        const placeholderHeight = evaluate(layoutExpression('// --- Placeholder when no media ---', 'height', 6))
        assert.equal(placeholderHeight + 2 * layout.content.anchors.topMargin, height)
      }
    }
  })
}
