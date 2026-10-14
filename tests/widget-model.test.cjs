const { test } = require('node:test')
const assert = require('node:assert/strict')
const model = require('../WidgetModel.js')

test('process names retain spaces and malformed samples are ignored', () => {
  assert.deepEqual(model.parseTopProcesses('123 Web Content 7.5 2.1\n123 broken xxx 3', 5),
    [{ pid: '123', name: 'Web Content', cpu: 7.5, mem: 2.1 }])
})
test('disk filters precede deduplication and mount paths can contain spaces', () => {
  const raw = 'Mounted Size Used Avail Use% Source\n/ 100G 50G 50G 50% /dev/test\n/home 100G 50G 50G 50% /dev/test\n/media/My Disk 10G 2G 8G 20% /dev/usb'
  assert.equal(model.parseDiskUsage(raw, ['/home'])[0].mount, '/home')
  assert.equal(model.parseDiskUsage(raw, []).at(-1).mount, '/media/My Disk')
})
test('blank temperature and optional GPU fields do not fabricate readings', () => {
  assert.equal(model.parseTemp('', 'CPU'), null)
  assert.equal(model.parseGpuTemp(''), null)
  assert.equal(model.parseGpuLine('15,100,200,[N/A]').utilization, 15)
  assert.equal(model.parseGpuLine('[N/A],100,200,50'), null)
})
test('temperature units convert without changing sensor source values', () => {
  assert.equal(model.convertTemperature(0, 'fahrenheit'), 32)
  assert.equal(model.convertTemperature(100, 'fahrenheit'), 212)
  assert.equal(model.convertTemperature(52, 'celsius'), 52)
})
test('memory and CPU snapshots provide consistent percentages', () => {
  const mem = model.parseMemInfo('MemTotal: 1000 kB\nMemAvailable: 250 kB\nMemFree: 100 kB')
  assert.equal(mem.percent, 75)
  assert.equal(model.parseMemInfo('').valid, false)
  const a = model.parseCpuStat('cpu  100 0 50 800 50 0 0 0')
  const b = model.parseCpuStat('cpu  120 0 60 860 60 0 0 0')
  assert.equal(model.cpuSnapshotPercent(a, b), 30)
  assert.equal(model.cpuSnapshotPercent(null, b), null)
  assert.equal(model.cpuSnapshotPercent(b, a), null)
})
test('network counters reset safely', () => {
  assert.deepEqual(model.netSpeed({rxBytes:100,txBytes:50},{rxBytes:300,txBytes:150},2000), {rx:100,tx:50})
  assert.deepEqual(model.netSpeed({rxBytes:100,txBytes:50},{rxBytes:0,txBytes:0},2000), {rx:0,tx:0})
})

const battery = (state, rate, extra = {}) => model.batteryPresentation({ ready: true, present: true, state, rate, ...extra })

test('battery uses state for flow direction across rate sign conventions', () => {
  assert.equal(battery('charging', 20.2464).power, '20.2 W in')
  assert.equal(battery('charging', -20.2464).power, '20.2 W in')
  assert.equal(battery('discharging', -8.1).power, '8.1 W out')
  assert.equal(battery('discharging', 8.1).power, '8.1 W out')
  assert.equal(battery('discharging', -0).power, '0.0 W out')
  assert.equal(battery('charging', 0.04).power, '<0.1 W in')
  assert.equal(battery('charged', 0).power, 'Idle')
})

test('battery does not fabricate power or percentage when unavailable', () => {
  for (const rate of [null, undefined, '', NaN, Infinity])
    assert.equal(battery('charging', rate).power, 'Power unavailable')
  assert.equal(battery('charged', 12).power, 'Idle')
  assert.equal(battery('pending-charge', null).power, 'Idle')
  assert.equal(battery('pending-discharge', null).power, 'Idle')
  assert.equal(battery('pending-charge', 0).status, 'Waiting to charge')
  assert.equal(battery('unknown', 0).power, 'Power unavailable')
  assert.equal(battery('charging', 20, { present: false }).status, 'No battery')
  assert.equal(battery('charging', 20, { ready: false }).status, 'Loading battery…')
})

test('malformed CPU and memory counters stay unavailable', () => {
  for (const raw of ['cpu 1', 'cpu x 0 0 5', 'cpu 1 0 0 -5', 'cpu Infinity 0 0 5'])
    assert.equal(model.parseCpuStat(raw), null)
  for (const available of ['garbage', 'Infinity', '-1', '2000']) {
    const memory = model.parseMemInfo(`MemTotal: 1000 kB\nMemAvailable: ${available} kB`)
    assert.equal(memory.valid, false)
    assert.equal(memory.usedGb, 0)
    assert.equal(memory.freeGb, 0)
  }
  const prior = model.parseCpuStat('cpu 100 0 50 800 50 0 0 0')
  const reset = model.parseCpuStat('cpu 90 0 60 900 50 0 0 0')
  assert.deepEqual(model.cpuBreakdown(prior, reset), {user:0, system:0})
})

test('default network route follows lowest metric and accepts direct tunnels', () => {
  const header = 'Iface Destination Gateway Flags RefCnt Use Metric Mask'
  const routes = `${header}\nwlan0 00000000 0100000A 0003 0 0 600 00000000\neth0 00000000 0100000A 0003 0 0 100 00000000`
  assert.equal(model.parseDefaultInterface(routes), 'eth0')
  assert.equal(model.parseDefaultInterface(routes + '\nwg0 00000000 00000000 0001 0 0 50 00000000'), 'wg0')
  assert.equal(model.parseDefaultInterface(routes + '\nbad0 00000000 00000000 0201 0 0 0 00000000'), 'eth0')
  assert.deepEqual(model.parseNetDev('eth0: nope 0 0 0 0 0 0 0 20'), {})
})

test('disk exclusions respect directory boundaries', () => {
  const raw = 'Mounted Size Used Avail Use% Source\n/run 1G 0G 1G 0% tmpfs\n/runtime-data 10G 2G 8G 20% /dev/data\n/tmp/archive 1G 0G 1G 0% /dev/temp\n/tmp-backup 10G 1G 9G 10% /dev/backup'
  assert.deepEqual(model.parseDiskUsage(raw, []).map(d => d.mount), ['/runtime-data', '/tmp-backup'])
})
