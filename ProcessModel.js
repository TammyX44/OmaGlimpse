// CPU uses the top/ps convention: 100% is one fully occupied logical CPU.
// Process utime + stime includes all threads, so CPU can exceed 100%.
// Only two snapshots of the same PID + starttime can produce a CPU reading.
var MAX_PROCESSES = 16384
var MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024

function integer(value, minimum) {
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value
    && value >= minimum && value <= 9007199254740991
}

function parseSnapshot(raw) {
  if (typeof raw !== "string" || raw.length > MAX_SNAPSHOT_BYTES)
    throw new Error("Process snapshot exceeds size limit")
  var snapshot = JSON.parse(raw)
  if (!snapshot || snapshot.version !== 1
      || typeof snapshot.sampledAt !== "number" || !isFinite(snapshot.sampledAt) || snapshot.sampledAt < 0
      || !integer(snapshot.clockTicks, 1) || snapshot.clockTicks > 1000000
      || !integer(snapshot.memoryTotalBytes, 1)
      || !Array.isArray(snapshot.processes) || snapshot.processes.length > MAX_PROCESSES)
    throw new Error("Invalid process snapshot")
  var seen = {}
  snapshot.processes.forEach(function(process) {
    if (!process || typeof process.pid !== "string" || !/^[1-9][0-9]{0,9}$/.test(process.pid)
        || typeof process.startTime !== "string" || !/^[0-9]{1,20}$/.test(process.startTime)
        || typeof process.name !== "string" || process.name.length > 256
        || !integer(process.cpuTicks, 0) || !integer(process.rssBytes, 0)
        || seen[process.pid])
      throw new Error("Invalid process entry")
    seen[process.pid] = true
    process.name = process.name.replace(/[\x00-\x1f\x7f]/g, " ")
  })
  return snapshot
}

function sample(snapshot, previous) {
  var elapsed = previous ? snapshot.sampledAt - previous.sampledAt : 0
  var ready = !!previous && elapsed > 0 && isFinite(elapsed)
    && previous.clockTicks === snapshot.clockTicks
  var old = {}
  if (ready) previous.processes.forEach(function(process) { old[process.pid] = process })
  return {
    ready: ready,
    processes: snapshot.processes.map(function(process) {
      var baseline = old[process.pid], cpu = null
      if (baseline && baseline.startTime === process.startTime && process.cpuTicks >= baseline.cpuTicks) {
        cpu = (process.cpuTicks - baseline.cpuTicks) / snapshot.clockTicks / elapsed * 100
        if (!isFinite(cpu)) cpu = null
      }
      return { pid: process.pid, startTime: process.startTime, name: process.name,
        cpu: cpu, mem: process.rssBytes / snapshot.memoryTotalBytes * 100 }
    })
  }
}

function topProcesses(processes, sortBy, count) {
  var field = sortBy === "mem" ? "mem" : "cpu"
  var limit = Math.max(1, Math.min(15, Math.floor(Number(count) || 5)))
  return processes.slice().sort(function(a, b) {
    var left = a[field] === null ? -1 : a[field]
    var right = b[field] === null ? -1 : b[field]
    return right - left || b.mem - a.mem || Number(a.pid) - Number(b.pid)
  }).slice(0, limit)
}

function samplingInterval(refreshInterval, multiplier) {
  var factor = Number(multiplier)
  if (!isFinite(factor) || factor < 1) factor = 1
  var interval = Number(refreshInterval)
  if (!isFinite(interval) || interval < 500) interval = 500
  return Math.min(2147483647, Math.ceil(interval * factor))
}

function formatPercent(value) {
  return typeof value === "number" && isFinite(value) ? value.toFixed(1) + "%" : "—"
}

if (typeof module !== "undefined") module.exports = {
  parseSnapshot: parseSnapshot, sample: sample, topProcesses: topProcesses,
  samplingInterval: samplingInterval, formatPercent: formatPercent
}
