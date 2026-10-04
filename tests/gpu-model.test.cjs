const { test } = require('node:test')
const assert = require('node:assert/strict')
const gpu = require('../GpuModel.js')
global.Quickshell = { env: () => '/tmp/widgets-test' }
const config = require('../WidgetConfig.js')

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

test('incremental Intel JSON handles partial, nested and quoted data', () => {
  let result = gpu.consumeIntelJson('', '[\n{"engines":{"Render/3D/0":{"busy":')
  assert.equal(result.objects.length, 0)
  result = gpu.consumeIntelJson(result.buffer, '15.5},"Video/0":{"busy":3}},"label":"a } \\" b"},\n{"engines":{"Render/3D/0":{"busy":0}}}')
  assert.equal(result.objects.length, 2)
  assert.equal(gpu.parseIntel(result.objects[0]), 15.5)
  assert.equal(gpu.parseIntel(result.objects[1]), 0)
  assert.equal(gpu.parseIntel({ engines: { Render: { busy: 'N/A' } } }), null)
  assert.equal(gpu.parseIntel({ engines: { Render: null } }), null)
  assert.equal(gpu.consumeIntelJson('{', 'x'.repeat(262144)).buffer, '')
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
