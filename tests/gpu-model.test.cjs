const { test } = require('node:test')
const assert = require('node:assert/strict')
const gpu = require('../lib/GpuModel.js')
global.Quickshell = { env: () => '/tmp/widgets-test' }
const config = require('../lib/WidgetConfig.js')

const inventory = gpu.parseInventory([
  '0000:01:00.0\tGA107 [GeForce RTX 3050]\tnvidia\tnvidia\t/sys/class/drm/card1\t\t\t\t\t/power\t0',
  '0000:00:02.0\tUHD Graphics\tintel\ti915\t/sys/class/drm/card2\t\t\t\t\t/power\t1',
  '0000:02:00.0\tRadeon RX 6800\tamd\tamdgpu\t/sys/class/drm/card3\t/temp\t/busy\t/used\t/total\t/power\t0'
].join('\n'))

test('mixed-vendor inventory is stable, named, and deduplicated by PCI identity', () => {
  assert.deepEqual(inventory.map(d => d.vendor), ['intel', 'nvidia', 'amd'])
  assert.equal(inventory[0].name, 'Intel UHD Graphics')
  assert.equal(inventory[0].kind, 'Integrated GPU')
  assert.equal(inventory[1].name, 'GeForce RTX 3050')
  assert.equal(gpu.pciId('00000000:01:00.0'), inventory[1].id)
  assert.equal(gpu.parseInventory('invalid').length, 0)
  assert.equal(gpu.deviceKind('Intel Arc Graphics', 'intel'), 'Intel GPU')
  assert.equal(gpu.deviceKind('Intel Arc A770', 'intel'), 'Discrete GPU')
  assert.equal(gpu.deviceKind('Intel Iris Xe MAX', 'intel'), 'Discrete GPU')
  assert.equal(inventory[2].kind, 'Discrete GPU')
})

test('NVIDIA reads every GPU and preserves unsupported fields', () => {
  const samples = gpu.parseNvidia('00000000:01:00.0, RTX 3050, 20, 123, 6144, 45\n00000000:02:00.0, RTX 4060, [N/A], N/A, 8192, N/A')
  assert.equal(Object.keys(samples).length, 2)
  assert.equal(samples['0000:01:00.0'].utilization, 20)
  assert.equal(samples['0000:02:00.0'].utilization, null)
  assert.equal(samples['0000:02:00.0'].memUsed, null)
  assert.equal(gpu.optionalNumber(''), null)
  assert.equal(gpu.optionalNumber('0'), 0)
  assert.equal(gpu.optionalNumber(true), null)
})

test('sleeping, stale, and unsupported devices stay selectable without false zeroes', () => {
  const samples = {
    '0000:00:02.0': { utilization: null, observedAt: 1000 },
    '0000:01:00.0': { sleeping: true },
    '0000:02:00.0': { utilization: 0, temp: 0, observedAt: 1000 }
  }
  const nvidia = { '0000:01:00.0': { utilization: 25, temp: 45, observedAt: 1000 } }
  let devices = gpu.resolveDevices(inventory, samples, nvidia, 2000, 5000)
  assert.deepEqual(devices.map(d => d.status), ['Unavailable', 'Sleeping', 'Ready'])
  assert.equal(devices[1].utilization, null)
  assert.equal(devices[2].utilization, 0)
  assert.equal(devices[2].temp, 0)
  devices = gpu.resolveDevices(inventory, samples, nvidia, 7000, 5000)
  assert.equal(devices[2].status, 'Stale')
  assert.equal(devices[2].utilization, null)
})

test('selection wraps in both directions and survives reordering, removal and empty inventories', () => {
  const id = inventory[1].id
  assert.equal(gpu.selectedIndex(inventory.toReversed(), id), 1)
  assert.equal(gpu.cycleDevice(inventory, id, 1), inventory[2].id)
  assert.equal(gpu.cycleDevice(inventory, inventory[0].id, -1), inventory[2].id)
  assert.equal(gpu.selectedIndex([inventory[0]], id), 0)
  assert.equal(gpu.selectedIndex([], id), -1)
  assert.equal(gpu.cycleDevice([], id, 1), '')
  assert.equal(gpu.cycleDevice([inventory[0]], id, 1), inventory[0].id)
})

test('intel_gpu_top CSV: busy columns come from the header, not fixed positions', () => {
  const header = 'Freq MHz req,Freq MHz act,IRQ /s,RC6 %,Power W gpu,Power W pkg,RCS %,RCS se,RCS wa,BCS %,BCS se,BCS wa,VCS %,VCS se,VCS wa,VECS %,VECS se,VECS wa'
  const columns = gpu.intelCsvColumns(header)
  assert.deepEqual(columns, [6, 9, 12, 15])
  assert.equal(gpu.isIntelCsvHeader(header), true)
  assert.equal(gpu.isIntelCsvHeader('473.446184,10.940983,118.361546,74.337066'), false)
  const row = '473.446184,10.940983,118.361546,74.337066,0.370378,15.320497,1.410807,0.000000,0.000000,7.250000,0,0,0.000000,0,0,3.000000,0,0\r'
  assert.equal(gpu.parseIntelCsv(row, columns), 7.25)
  assert.equal(gpu.parseIntelCsv('  ' + row + '  ', columns), 7.25)
  // RC6 residency is high when the GPU is idle; it must never count as load.
  assert.equal(gpu.parseIntelCsv('0,0,0,99.5,0,0,0,0,0,0,0,0,0,0,0,0,0,0', columns), 0)
  assert.equal(gpu.parseIntelCsv('0,0,0,0,0,0,250,0,0,0,0,0,0,0,0,0,0,0', columns), 100)
})

test('intel_gpu_top CSV: physical-engine names from -p and other GPUs', () => {
  const columns = gpu.intelCsvColumns('Freq MHz req,RC6 %,Power W gpu,RCS/0 %,RCS/0 se,CCS/0 %,CCS/0 se,VCS/1 %\r')
  assert.deepEqual(columns, [3, 5, 7])
  assert.equal(gpu.parseIntelCsv('300,50,1.2,4,0,18.5,0,9', columns), 18.5)
  assert.deepEqual(gpu.intelCsvColumns('CCS %,RC6 %'), [0])
  assert.deepEqual(gpu.intelCsvColumns('rc6 %,RCS %'), [1])
})

test('intel_gpu_top CSV: malformed rows and header-only streams yield nothing', () => {
  const columns = gpu.intelCsvColumns('RC6 %,RCS %,BCS %')
  assert.equal(gpu.parseIntelCsv('74,N/A,3', columns), null)
  assert.equal(gpu.parseIntelCsv('74,5', columns), null)
  assert.equal(gpu.parseIntelCsv('74,,3', columns), null)
  assert.equal(gpu.parseIntelCsv('74,-1,3', columns), null)
  assert.equal(gpu.parseIntelCsv('', columns), null)
  assert.equal(gpu.parseIntelCsv(undefined, columns), null)
  // Header only: no busy columns at all, so a row can never become a reading.
  assert.deepEqual(gpu.intelCsvColumns('Freq MHz req,RC6 %,Power W gpu'), [])
  assert.deepEqual(gpu.intelCsvColumns(''), [])
  assert.equal(gpu.parseIntelCsv('473,74,0.3', gpu.intelCsvColumns('Freq MHz req,RC6 %,Power W gpu')), null)
  assert.equal(gpu.parseIntelCsv('473,74,0.3', []), null)
  assert.equal(gpu.parseIntelCsv('473,74,0.3', undefined), null)
})

test('GPU preferences migrate safely, preserve aliases and reject malformed values', () => {
  const old = config.parseConfig('{}').widgets.systemMonitor
  assert.equal(old.gpuDevice, '')
  assert.deepEqual(old.gpuAliases, {})
  const saved = config.parseConfig(JSON.stringify({ widgets: { systemMonitor: {
    gpuDevice: inventory[1].id, gpuAliases: { [inventory[1].id]: ' Compute GPU\n ', invalid: 'oops', [inventory[0].id]: 42 }
  } } })).widgets.systemMonitor
  assert.equal(saved.gpuDevice, inventory[1].id)
  assert.deepEqual(saved.gpuAliases, { [inventory[1].id]: 'Compute GPU' })
  assert.equal(gpu.displayName(inventory[1], saved.gpuAliases), 'Compute GPU')
  assert.equal(gpu.displayName(inventory[0], saved.gpuAliases), 'Integrated GPU')
  assert.equal(gpu.displayName(inventory[1], {}), 'Discrete GPU')
  assert.equal(gpu.displayName(inventory[1], { [inventory[1].id]: '  ' }), 'Discrete GPU')
  assert.equal(gpu.displayName({ id: '0000:00:02.0', name: 'Intel Arc Graphics', kind: 'Intel GPU' }, {}), 'Intel GPU')
  assert.equal(config.parseConfig('{"widgets":{"systemMonitor":{"gpuAliases":[]}}}').widgets.systemMonitor.gpuDevice, '')
  assert.equal(config.parseConfig('{"widgets":{"systemMonitor":{"gpuDevice":"invalid"}}}').widgets.systemMonitor.gpuDevice, '')
})
