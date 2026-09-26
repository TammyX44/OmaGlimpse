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
