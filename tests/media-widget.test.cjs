const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const source = fs.readFileSync(path.join(__dirname, '../MediaWidget.qml'), 'utf8')
// Quickshell's MprisPlaybackState Enum is ordered Stopped, Playing, Paused.
const MprisPlaybackState = { Stopped: 0, Playing: 1, Paused: 2 }

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

const context = { MprisLoopState: { None: 0, Track: 1, Playlist: 2 } }
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
    playbackState: MprisPlaybackState.Paused,
    trackTitle: 'Fixture track',
    trackArtist: 'Fixture artist',
    length: 180,
    lengthSupported: true,
    position: 55,
    positionSupported: true,
    canSeek: true,
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
  assert.equal((source.match(/Accessible\.role: Accessible\.Button/g) || []).length, 4)
  assert.equal((source.match(/activeFocusOnTab: enabled/g) || []).length, 4)
  assert.equal((source.match(/Keys\.onReturnPressed:/g) || []).length, 4)
  assert.equal((source.match(/Keys\.onEnterPressed:/g) || []).length, 4)
  assert.equal((source.match(/Keys\.onSpacePressed:/g) || []).length, 4)
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

// Read the state bindings and handlers from QML so timing assertions exercise
// production logic, including any helpers added to reset a player switch.
function timingState(activePlayer, overrides = {}) {
  const scope = { Date, MprisPlaybackState, root: { activePlayer, samplingEnabled: true, visible: true,
    livePosition: 55, positionSampleAt: 0, seeking: false, seekPreview: 0, ...overrides } }
  vm.createContext(scope)
  for (const match of source.matchAll(/^  function (\w+)\(/gm)) {
    vm.runInContext(extractFunction(match[1]), scope)
    scope.root[match[1]] = scope[match[1]]
  }
  for (const name of ['samplingActive', 'hasMedia', 'isPlaying', 'trackLength',
    'durationAvailable', 'positionAvailable', 'timelineAvailable', 'canSeek', 'shownPosition', 'progress']) {
    const declaration = source.match(new RegExp(`^  readonly property \\w+ ${name}: ([^\\n]+(?:\\n {4,}[^\\n]+)*)`, 'm'))
    assert.ok(declaration, `missing ${name} timing contract`)
    const expression = declaration[1].trim()
    Object.defineProperty(scope.root, name, { configurable: true, get() {
      return vm.runInContext(expression.startsWith('{')
        ? `(function() ${expression})()` : `(${expression})`, scope)
    } })
  }
  // QML permits unqualified root properties inside functions and bindings.
  for (const name of Object.getOwnPropertyNames(scope.root)) {
    Object.defineProperty(scope, name, { configurable: true,
      get: () => scope.root[name], set: value => { scope.root[name] = value } })
  }
  return { root: scope.root, evaluate: expression => vm.runInContext(`(${expression})`, scope),
    switchPlayer(player) {
      scope.root.activePlayer = player
      const marker = source.indexOf('  onActivePlayerChanged:')
      assert.notEqual(marker, -1, 'missing active-player reset handler')
      const start = source.indexOf('{', marker)
      let depth = 0
      for (let i = start; i < source.length; i++) {
        if (source[i] === '{') depth++
        else if (source[i] === '}' && --depth === 0) {
          vm.runInContext(source.slice(start + 1, i), scope)
          return
        }
      }
      assert.fail('unterminated active-player reset handler')
    } }
}

function timeLabel(state, name) {
  return state.evaluate(layoutExpression(`objectName: "${name}"`, 'text', 8))
}

test('unknown duration retains a visible timeline with unavailable time placeholders', () => {
  const state = timingState(fakePlayer({ isPlaying: true, length: 0, positionSupported: false, position: -1 }))
  assert.equal(state.root.durationAvailable, false)
  assert.equal(state.root.positionAvailable, false)
  assert.equal(state.root.timelineAvailable, true)
  assert.equal(state.evaluate(layoutExpression('id: seekRow', 'visible', 6)), true)
  assert.equal(timeLabel(state, 'mediaElapsedTime'), '--:--')
  assert.equal(timeLabel(state, 'mediaDurationTime'), '--:--')
  assert.equal(state.root.progress, 0)
  assert.equal(state.root.canSeek, false)
  const knownPosition = timingState(fakePlayer({ length: 0, position: 55 }))
  assert.equal(knownPosition.root.positionAvailable, true)
  assert.equal(timeLabel(knownPosition, 'mediaElapsedTime'), '0:55')
  assert.equal(timeLabel(knownPosition, 'mediaDurationTime'), '--:--')
  assert.equal(knownPosition.root.progress, 0)
  assert.equal(knownPosition.root.canSeek, false)
})

test('Quickshell position-as-length fallback is not a real duration', () => {
  const state = timingState(fakePlayer({ length: 55, lengthSupported: false, position: 55 }))
  assert.equal(state.root.trackLength, 0)
  assert.equal(state.root.positionAvailable, true)
  assert.equal(state.root.canSeek, false)
  assert.equal(state.root.progress, 0)
  assert.equal(timeLabel(state, 'mediaElapsedTime'), '0:55')
  assert.equal(timeLabel(state, 'mediaDurationTime'), '--:--')
})

test('only finite positive duration and finite supported nonnegative position are available', () => {
  for (const length of [0, -1, NaN, Infinity, -Infinity]) {
    const state = timingState(fakePlayer({ length }))
    assert.equal(state.root.trackLength, 0, `invalid duration ${length}`)
    assert.equal(state.root.durationAvailable, false)
    assert.equal(timeLabel(state, 'mediaDurationTime'), '--:--')
    assert.equal(state.root.canSeek, false)
    assert.equal(state.root.progress, 0)
  }
  for (const position of [-1, NaN, Infinity, -Infinity]) {
    const state = timingState(fakePlayer({ position }), { livePosition: position })
    assert.equal(state.root.positionAvailable, false, `invalid position ${position}`)
    assert.equal(timeLabel(state, 'mediaElapsedTime'), '--:--')
    assert.equal(state.root.canSeek, false)
    assert.equal(state.root.progress, 0)
  }
  const zero = timingState(fakePlayer({ position: 0 }), { livePosition: 0 })
  assert.equal(zero.root.positionAvailable, true)
  assert.equal(timeLabel(zero, 'mediaElapsedTime'), '0:00')
  for (const position of [180, 200]) {
    const state = timingState(fakePlayer({ position }), { livePosition: position })
    assert.equal(state.root.progress, 1, 'progress must stop at the end of the bar')
  }
})

test('active playback without track metadata retains timeline and transport', () => {
  const state = timingState(fakePlayer({ isPlaying: true, trackTitle: '', trackArtist: '', length: 0,
    positionSupported: false, position: -1 }), { showControls: true })
  assert.equal(state.root.hasMedia, true)
  assert.equal(state.root.timelineAvailable, true)
  assert.equal(state.evaluate(layoutExpression('id: transportRow', 'visible', 6)), true)
  assert.equal(state.root.canRunAction('playPause', state.root.activePlayer), false)
  state.root.activePlayer.canPause = true
  assert.equal(state.root.runAction('playPause'), true)
  assert.deepEqual(state.root.activePlayer.calls, ['pause'])
})

test('paused playback without metadata retains timeline and playable transport', () => {
  const state = timingState(fakePlayer({ isPlaying: false, playbackState: MprisPlaybackState.Paused,
    trackTitle: '', trackArtist: '', length: 0, positionSupported: false, position: -1, canPlay: true }),
  { showControls: true })
  assert.equal(state.root.hasMedia, true)
  assert.equal(state.root.timelineAvailable, true)
  assert.equal(state.evaluate(layoutExpression('id: transportRow', 'visible', 6)), true)
  assert.equal(timeLabel(state, 'mediaElapsedTime'), '--:--')
  assert.equal(timeLabel(state, 'mediaDurationTime'), '--:--')
  assert.equal(state.root.runAction('playPause'), true)
  assert.deepEqual(state.root.activePlayer.calls, ['play'])
})

test('playing without metadata wins over paused metadata in the actual player-selection binding', () => {
  const marker = source.indexOf('  readonly property var activePlayer:')
  assert.notEqual(marker, -1)
  const start = source.indexOf('{', marker)
  let depth = 0
  let body
  for (let i = start; i < source.length; i++) {
    if (source[i] === '{') depth++
    else if (source[i] === '}' && --depth === 0) {
      body = source.slice(start + 1, i)
      break
    }
  }
  assert.ok(body, 'missing selection binding body')
  const paused = fakePlayer({ dbusName: 'org.mpris.MediaPlayer2.paused' })
  const playing = fakePlayer({ dbusName: 'org.mpris.MediaPlayer2.stream', isPlaying: true,
    trackTitle: '', trackArtist: '', length: 0 })
  function select(players) {
    const scope = { players, MprisPlaybackState, root: { players, playerUpdateNonce: 0 } }
    vm.createContext(scope)
    vm.runInContext(extractFunction('isProxyPlayer') + '\n' + extractFunction('hasTrackMetadata'), scope)
    scope.root.isProxyPlayer = scope.isProxyPlayer
    scope.root.hasTrackMetadata = scope.hasTrackMetadata
    return vm.runInContext(`(function() { ${body} })()`, scope)
  }
  for (const players of [[paused, playing], [playing, paused]]) assert.equal(select(players), playing)
  const proxy = fakePlayer({ dbusName: 'org.mpris.MediaPlayer2.playerctld', desktopEntry: 'playerctld',
    isPlaying: true, trackTitle: '', trackArtist: '' })
  assert.equal(select([paused, proxy]), proxy)
  assert.equal(select([proxy, playing, paused]), playing, 'regular active player precedes its proxy')
  const browser = fakePlayer({ desktopEntry: 'plasma-browser-integration', isPlaying: true,
    trackTitle: '', trackArtist: '' })
  assert.equal(select([paused, browser]), browser, 'active browser survives transient missing metadata')
  browser.isPlaying = false
  assert.equal(select([browser, paused]), paused, 'inactive empty browser proxy remains excluded')
  const idle = fakePlayer({ dbusName: 'org.mpris.MediaPlayer2.idle', trackTitle: '', trackArtist: '',
    playbackState: MprisPlaybackState.Stopped })
  const pausedStream = fakePlayer({ dbusName: 'org.mpris.MediaPlayer2.pausedStream',
    trackTitle: '', trackArtist: '', playbackState: MprisPlaybackState.Paused })
  assert.equal(select([idle, pausedStream]), pausedStream, 'paused stream stays available over an idle source')
  browser.playbackState = MprisPlaybackState.Paused
  assert.equal(select([idle, browser]), browser, 'paused browser without metadata keeps its resume controls')
  assert.equal(select([pausedStream, paused]), paused, 'paused source with metadata still has priority')
})

test('known timing shows real values even when seeking is unsupported', () => {
  for (const canSeek of [true, false]) {
    const state = timingState(fakePlayer({ canSeek }))
    assert.equal(state.root.durationAvailable, true)
    assert.equal(state.root.positionAvailable, true)
    assert.equal(state.root.timelineAvailable, true)
    assert.equal(timeLabel(state, 'mediaElapsedTime'), '0:55')
    assert.equal(timeLabel(state, 'mediaDurationTime'), '3:00')
    assert.equal(state.root.progress, 55 / 180)
    assert.equal(state.root.canSeek, canSeek)
    state.root.previewSeek(0.75)
    state.root.commitSeek()
    assert.equal(state.root.activePlayer.position, canSeek ? 135 : 55)
    assert.equal(state.root.seeking, false)
  }
  const unavailable = timingState(fakePlayer({ positionSupported: false }))
  assert.equal(timeLabel(unavailable, 'mediaElapsedTime'), '--:--')
  assert.equal(timeLabel(unavailable, 'mediaDurationTime'), '3:00')
  assert.equal(unavailable.root.canSeek, false)
  assert.equal(unavailable.root.progress, 0)
})

test('switching players clears an in-flight seek and samples the new player', () => {
  for (const samplingEnabled of [true, false]) {
    const old = fakePlayer()
    const state = timingState(old, { samplingEnabled, livePosition: 120, seeking: true, seekPreview: 160 })
    const next = fakePlayer({ position: 12 })
    state.switchPlayer(next)
    assert.equal(state.root.seeking, false, 'old drag must not survive a player switch')
    assert.equal(state.root.seekPreview, 0, 'old seek preview must be cleared')
    assert.equal(state.root.livePosition, 12, 'switch must sample even while periodic sampling is disabled')
    assert.equal(state.root.shownPosition, 12)
    assert.equal(state.root.progress, 12 / 180)
    state.root.commitSeek()
    assert.equal(next.position, 12, 'releasing an old drag must not seek the new player')
    assert.equal(old.position, 55)
    state.switchPlayer(fakePlayer({ length: 0, position: -1, positionSupported: false }))
    assert.equal(state.root.livePosition, 0)
    assert.equal(state.root.progress, 0)
    assert.equal(timeLabel(state, 'mediaElapsedTime'), '--:--')
    state.switchPlayer(null)
    assert.equal(state.root.livePosition, 0)
    assert.equal(state.root.seeking, false)
    assert.equal(state.root.timelineAvailable, false)
  }
})

test('commit rejects a drag after timing or seek capability disappears', () => {
  for (const replacement of [null, fakePlayer({ canSeek: false }),
    fakePlayer({ positionSupported: false }), fakePlayer({ length: 0 })]) {
    const state = timingState(fakePlayer(), { seeking: true, seekPreview: 135 })
    state.root.activePlayer = replacement
    assert.doesNotThrow(() => state.root.commitSeek())
    assert.equal(state.root.seeking, false)
    if (replacement) assert.equal(replacement.position, 55, 'unsupported player must not receive the old seek')
    assert.notEqual(state.root.livePosition, 135, 'rejected seek must not change cached progress')
  }
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
    root: { showControls, showAlbumArt, width: 340, hasMedia: false, timelineAvailable: false,
      durationAvailable: false, positionAvailable: false, trackLength: 0, widgetCfg: { cardHeight: 0 } },
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
  binding(layout.transportRow, 'width', layoutExpression('id: transportRow', 'width', 6), layout.content)
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
  { name: 'idle', hasMedia: false, timelineAvailable: false, trackLength: 0, isPlaying: false },
  { name: 'metadata without duration', hasMedia: true, timelineAvailable: true, trackLength: 0, isPlaying: false },
  { name: 'playing without metadata', hasMedia: true, timelineAvailable: true, trackLength: 0, isPlaying: true },
  { name: 'paused without metadata', hasMedia: true, timelineAvailable: true, trackLength: 0, isPlaying: false },
  { name: 'playing seekable track', hasMedia: true, timelineAvailable: true, trackLength: 180, isPlaying: true },
  { name: 'paused seekable track', hasMedia: true, timelineAvailable: true, trackLength: 180, isPlaying: false },
  { name: 'stopped', hasMedia: false, timelineAvailable: false, trackLength: 0, isPlaying: false }
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
          assert.equal(root.transportButtonSize, width === 200 ? 28 : 44)
          assert.equal(layout.trackInfo.height, 64)
          assert.equal(layout.content.anchors.topMargin, width === 200 && showControls && state.hasMedia ? 24 : 16)
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
            assert.equal(seekRow.visible, state.timelineAvailable, `${label}: timeline silently hidden`)
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


test('repeat cycles off, playlist, track, off on the displayed player only', () => {
  const player = fakePlayer({ canControl: true, loopSupported: true, loopState: 0 })
  const other = fakePlayer({ canControl: true, loopSupported: true, loopState: 0 })
  usePlayer(player, [other])
  for (const expected of [2, 1, 0]) {
    assert.equal(context.runAction('loop'), true)
    assert.equal(player.loopState, expected)
    assert.equal(other.loopState, 0)
  }
  for (const overrides of [{ canControl: false }, { loopSupported: false }]) {
    const unsupported = fakePlayer({ canControl: true, loopSupported: true, loopState: 0, ...overrides })
    usePlayer(unsupported)
    assert.equal(context.runAction('loop'), false)
    assert.equal(unsupported.loopState, 0)
  }
})
