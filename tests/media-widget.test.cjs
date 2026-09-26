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
  extractFunction('runAction')
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
