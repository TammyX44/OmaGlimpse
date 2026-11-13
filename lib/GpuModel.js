// GPU identities and readings are kept separate: a sleeping or unsupported
// device must stay selectable without turning missing readings into 0%.
function optionalNumber(value) {
  if (typeof value !== "number" && typeof value !== "string") return null
  if (value === null || value === undefined || String(value).trim() === "") return null
  var n = Number(value)
  return isFinite(n) && n >= 0 ? n : null
}

function pciId(value) {
  var match = String(value || "").trim().toLowerCase().match(/^([0-9a-f]{4,8}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])$/)
  return match ? match[1].slice(-4) + ":" + match[2] + ":" + match[3] + "." + match[4] : ""
}

function deviceKind(name, vendor) {
  if (/\bintegrated\b|\bUHD\b|\bHD Graphics\b|\bIris\b(?!.*\bMAX\b)/i.test(name)) return "Integrated GPU"
  if (/\bGeForce\b|\bQuadro\b|\bRTX\b|\bGTX\b|\bArc [AB]\d{3}\b|\bIris Xe MAX\b|\bRadeon (?:RX \d{3,4}|PRO W\d{3,4})\b/i.test(name)) return "Discrete GPU"
  return vendor === "intel" ? "Intel GPU" : vendor === "amd" ? "AMD GPU" : vendor === "nvidia" ? "NVIDIA GPU" : "GPU"
}

function parseInventory(raw) {
  var out = [], seen = {}
  String(raw || "").trim().split(/\r?\n/).forEach(function(line) {
    var p = line.split("\t"), id = pciId(p[0])
    if (!id || p.length < 11 || seen[id]) return
    seen[id] = true
    var vendor = p[2], name = p[1]
    // PCI database names often include a friendlier product name in brackets.
    var friendly = name.match(/\[([^\]]+)\]/)
    if (friendly) name = friendly[1]
    if (!name) name = (vendor === "intel" ? "Intel" : vendor === "amd" ? "AMD" : vendor === "nvidia" ? "NVIDIA" : "Unknown") + " GPU"
    if (vendor === "intel" && !/^Intel\b/i.test(name)) name = "Intel " + name
    out.push({ id: id, name: name, vendor: vendor, driver: p[3], cardPath: p[4],
      tempPath: p[5], busyPath: p[6], memUsedPath: p[7], memTotalPath: p[8],
      runtimePath: p[9], intelTool: p[10] === "1", kind: deviceKind(name, vendor) })
  })
  return out.sort(function(a, b) { return a.id.localeCompare(b.id) })
}

function parseNvidia(raw) {
  var out = {}
  String(raw || "").trim().split(/\r?\n/).forEach(function(line) {
    var p = line.split(/,\s*/), id = pciId(p[0])
    if (!id || p.length < 6) return
    var utilization = optionalNumber(p[2])
    out[id] = { name: p[1].trim(), utilization: utilization === null ? null : Math.min(100, utilization),
      memUsed: optionalNumber(p[3]), memTotal: optionalNumber(p[4]), temp: optionalNumber(p[5]) }
  })
  return out
}

// intel_gpu_top -c prints one CSV header line, then one line per sample.
// Engine utilisation columns are the headers ending in " %" (RCS %, VCS %,
// "RCS/0 %" with -p, ...) except RC6 residency, which is power state, not load.
function intelCsvColumns(headerLine) {
  var columns = []
  String(headerLine || "").split(",").forEach(function(name, index) {
    name = name.trim()
    if (/\s%$/.test(name) && !/^RC6\b/i.test(name)) columns.push(index)
  })
  return columns
}

// Busiest engine for one CSV sample line, clamped to 0..100, or null when any
// engine column is missing or not a number.
function parseIntelCsv(line, columns) {
  if (!columns || !columns.length) return null
  var fields = String(line || "").trim().split(",")
  var max = null
  for (var i = 0; i < columns.length; i++) {
    var field = fields[columns[i]]
    var busy = field === undefined ? null : optionalNumber(field.trim())
    if (busy === null) return null
    max = Math.max(max === null ? 0 : max, Math.min(100, busy))
  }
  return max
}

// A header names its columns; sample rows are only numbers.
function isIntelCsvHeader(line) {
  return /[A-Za-z]/.test(String(line || ""))
}

function resolveDevices(inventory, samples, nvidia, now, staleAfter) {
  return inventory.map(function(device) {
    var local = samples[device.id] || {}, reading = device.vendor === "nvidia" ? (nvidia[device.id] || {}) : local
    var sleeping = local.sleeping === true
    var fresh = !sleeping && reading.observedAt > 0 && now - reading.observedAt <= staleAfter
    var utilization = fresh ? optionalNumber(reading.utilization) : null
    return { id: device.id, name: reading.name || device.name, kind: deviceKind(reading.name || device.name, device.vendor),
      vendor: device.vendor, utilization: utilization, temp: fresh ? optionalNumber(reading.temp) : null,
      memUsed: fresh ? optionalNumber(reading.memUsed) : null, memTotal: fresh ? optionalNumber(reading.memTotal) : null,
      status: sleeping ? "Sleeping" : !fresh && reading.observedAt > 0 ? "Stale" : utilization === null ? "Unavailable" : "Ready" }
  })
}

function selectedIndex(devices, selectedId) {
  for (var i = 0; i < devices.length; i++) if (devices[i].id === selectedId) return i
  return devices.length ? 0 : -1
}

function cycleDevice(devices, selectedId, step) {
  var index = selectedIndex(devices, selectedId)
  return index < 0 ? "" : devices[(index + step % devices.length + devices.length) % devices.length].id
}

function displayName(device, aliases) {
  var custom = aliases && typeof aliases[device.id] === "string" ? aliases[device.id].trim() : ""
  return custom || device.kind || device.name
}

if (typeof module !== "undefined") module.exports = {
  optionalNumber: optionalNumber, pciId: pciId, deviceKind: deviceKind, parseInventory: parseInventory,
  parseNvidia: parseNvidia, intelCsvColumns: intelCsvColumns, parseIntelCsv: parseIntelCsv,
  isIntelCsvHeader: isIntelCsvHeader,
  resolveDevices: resolveDevices, selectedIndex: selectedIndex, cycleDevice: cycleDevice, displayName: displayName
}
