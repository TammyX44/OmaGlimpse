const { test } = require('node:test')
const assert = require('node:assert/strict')
const model = require('../ProcessModel.js')

function process(pid, cpuTicks, startTime = '10', rssBytes = 100, name = 'worker') {
  return { pid: String(pid), startTime, cpuTicks, rssBytes, name }
}
function snapshot(sampledAt, processes, overrides = {}) {
  return model.parseSnapshot(JSON.stringify({ version: 1, sampledAt, clockTicks: 100,
    memoryTotalBytes: 1000, processes, ...overrides }))
}

test('first sample has memory immediately and CPU is unknown, then idle is a valid zero', () => {
  const first = snapshot(10, [process(1, 10000)])
  const initial = model.sample(first, null)
  assert.equal(initial.ready, false)
  assert.equal(initial.processes[0].cpu, null)
  assert.equal(initial.processes[0].mem, 10)
  const next = model.sample(snapshot(12, [process(1, 10000)]), first)
  assert.equal(next.ready, true)
  assert.equal(next.processes[0].cpu, 0)
  assert.equal(model.formatPercent(null), '—')
  assert.equal(model.formatPercent(0), '0.0%')
})

test('interval CPU ignores lifetime totals and counts all threads at 100% per core', () => {
  const first = snapshot(10, [process(1, 1000000), process(2, 1), process(3, 0)])
  const next = model.sample(snapshot(12, [process(1, 1000050), process(2, 201), process(3, 800)]), first)
  assert.deepEqual(next.processes.map(p => p.cpu), [25, 100, 400])
  assert.deepEqual(model.topProcesses(next.processes, 'cpu', 3).map(p => p.pid), ['3', '2', '1'])
})

test('PID reuse, newly born processes, exits, and counter rollback reset only affected readings', () => {
  const first = snapshot(1, [process(1, 500), process(2, 100), process(3, 50), process(4, 0)])
  const current = snapshot(2, [process(1, 700, '11'), process(2, 99), process(4, 50), process(5, 900)])
  const next = model.sample(current, first)
  assert.deepEqual(next.processes.map(p => [p.pid, p.cpu]), [['1', null], ['2', null], ['4', 50], ['5', null]])
  const recovered = model.sample(snapshot(3, [process(1, 800, '11'), process(2, 100)]), current)
  assert.deepEqual(recovered.processes.map(p => p.cpu), [100, 1])
})

test('same/reversed sample time and changed clock units rebaseline instead of dividing invalid deltas', () => {
  const first = snapshot(10, [process(1, 100)])
  for (const current of [snapshot(10, [process(1, 150)]), snapshot(9, [process(1, 150)]),
    snapshot(11, [process(1, 150)], { clockTicks: 250 })]) {
    const result = model.sample(current, first)
    assert.equal(result.ready, false)
    assert.equal(result.processes[0].cpu, null)
  }
  const reset = snapshot(9, [process(1, 150)])
  assert.equal(model.sample(snapshot(10, [process(1, 175)]), reset).processes[0].cpu, 25)
})

test('every process remains in baseline, allowing a previously unranked process to become top', () => {
  const first = snapshot(1, [process(1, 0), process(2, 0, '10', 300)])
  const next = snapshot(2, [process(1, 100), process(2, 1, '10', 300)])
  assert.equal(model.topProcesses(model.sample(next, first).processes, 'cpu', 1)[0].pid, '1')
  const result = model.sample(snapshot(3, [process(1, 100), process(2, 201, '10', 300)]), next)
  assert.equal(model.topProcesses(result.processes, 'cpu', 1)[0].cpu, 200)
  assert.equal(model.topProcesses(result.processes, 'mem', 1)[0].pid, '2')
  assert.deepEqual(result.processes.map(p => p.pid), ['1', '2'], 'ranking does not mutate sample')
})

test('ranking is bounded and deterministic, with unknown CPU below measured zero', () => {
  const rows = [{ pid: '4', cpu: null, mem: 99 }, { pid: '3', cpu: 0, mem: 1 },
    { pid: '2', cpu: 0, mem: 1 }]
  assert.deepEqual(model.topProcesses(rows, 'cpu', 15).map(p => p.pid), ['2', '3', '4'])
  assert.equal(model.topProcesses(rows, 'mem', 1)[0].pid, '4')
  assert.equal(model.topProcesses(rows, 'cpu', -1).length, 1)
  assert.equal(model.topProcesses(Array.from({ length: 30 }, (_, i) => ({ pid: String(i + 1), cpu: 0, mem: 0 })), 'cpu', 99).length, 15)
})

test('snapshot parser rejects partial, ambiguous, invalid, duplicate and oversized records', () => {
  for (const raw of ['', 'null', '{', '{}', 'x'.repeat(8 * 1024 * 1024 + 1)])
    assert.throws(() => model.parseSnapshot(raw))
  for (const overrides of [{ clockTicks: 0 }, { clockTicks: '100' }, { sampledAt: -1 },
    { memoryTotalBytes: 0 }, { memoryTotalBytes: '1000' }, { processes: {} }, { version: 2 }])
    assert.throws(() => snapshot(1, [], overrides))
  for (const overrides of [{ pid: '0' }, { pid: 1 }, { startTime: 1 }, { cpuTicks: -1 },
    { cpuTicks: Number.MAX_SAFE_INTEGER + 1 }, { rssBytes: '1' }, { name: 'a'.repeat(257) }])
    assert.throws(() => snapshot(1, [{ ...process(1, 0), ...overrides }]))
  assert.throws(() => snapshot(1, [process(1, 0), process(1, 1)]))
  assert.throws(() => snapshot(1, Array.from({ length: 16385 }, (_, i) => process(i + 1, 0))))
  assert.equal(snapshot(1, [process(1, 0, '99999999999999999999', 0, 'a\nb\0')]).processes[0].name, 'a b ')
})

test('interval multiplier cannot overflow QML timers or accelerate below the base interval', () => {
  assert.equal(model.samplingInterval(2000, 1), 2000)
  assert.equal(model.samplingInterval(2000, 3), 6000)
  assert.equal(model.samplingInterval(500, 1.5), 750)
  for (const multiplier of [0, -1, NaN, Infinity]) assert.equal(model.samplingInterval(2000, multiplier), 2000)
  assert.equal(model.samplingInterval(2000, 1e100), 2147483647)
  assert.equal(model.samplingInterval(1, 1), 500)
})
