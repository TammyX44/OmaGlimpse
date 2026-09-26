// Data parsing helpers for the desktop widgets.

function parseCpuLine(raw) {
  var parts = String(raw || "").split("\t")
  if (parts.length < 3) return null
  var idle = Number(parts[1])
  var total = Number(parts[2])
  if (!isFinite(idle) || !isFinite(total)) return null
  return { idle: idle, total: total }
}

function cpuPercent(prev, curr) {
  if (!prev || !curr) return 0
  var dIdle = curr.idle - prev.idle
  var dTotal = curr.total - prev.total
  if (dTotal <= 0) return 0
  var pct = ((dTotal - dIdle) / dTotal) * 100
  return Math.max(0, Math.min(100, pct))
}

function parseMemoryLine(raw) {
  var n = Number(String(raw || "").split("\t")[1])
  return isFinite(n) ? Math.max(0, Math.min(100, n)) : 0
}

// Parse /proc/meminfo for detailed RAM info
function parseMemInfo(raw) {
  var lines = String(raw || "").split("\n")
  var info = { total: 0, available: 0, free: 0 }
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf("MemTotal:") === 0) info.total = Number(line.split(/\s+/)[1]) || 0
    else if (line.indexOf("MemAvailable:") === 0) info.available = Number(line.split(/\s+/)[1]) || 0
    else if (line.indexOf("MemFree:") === 0) info.free = Number(line.split(/\s+/)[1]) || 0
  }
  info.valid = info.total > 0 && /(?:^|\n)MemAvailable:/.test(String(raw || ""))
    && info.available >= 0 && info.available <= info.total
  info.percent = info.valid ? (1 - info.available / info.total) * 100 : 0
  info.usedKb = info.total - info.available
  info.usedGb = info.usedKb / 1024 / 1024
  info.freeGb = info.available / 1024 / 1024
  info.totalGb = info.total / 1024 / 1024
  return info
}

// Parse /proc/stat for CPU system/user breakdown
function parseCpuStat(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("cpu ") === 0) {
      var cols = lines[i].split(/\s+/)
      // user, nice, system, idle, iowait, irq, softirq, steal
      return {
        user: Number(cols[1]) || 0,
        nice: Number(cols[2]) || 0,
        system: Number(cols[3]) || 0,
        idle: Number(cols[4]) || 0,
        iowait: Number(cols[5]) || 0,
        irq: Number(cols[6]) || 0,
        softirq: Number(cols[7]) || 0,
        steal: Number(cols[8]) || 0
      }
    }
  }
  return null
}

function cpuBreakdown(prev, curr) {
  if (!prev || !curr) return { user: 0, system: 0 }
  var dTotal = (curr.user + curr.nice + curr.system + curr.idle + curr.iowait + curr.irq + curr.softirq + curr.steal)
             - (prev.user + prev.nice + prev.system + prev.idle + prev.iowait + prev.irq + prev.softirq + prev.steal)
  if (dTotal <= 0) return { user: 0, system: 0 }
  var dUser = (curr.user + curr.nice) - (prev.user + prev.nice)
  var dSystem = (curr.system + curr.irq + curr.softirq) - (prev.system + prev.irq + prev.softirq)
  return {
    user: Math.round((dUser / dTotal) * 100),
    system: Math.round((dSystem / dTotal) * 100)
  }
}

function cpuSnapshotPercent(prev, curr) {
  if (!prev || !curr) return null
  var keys = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"]
  var total = 0
  for (var i = 0; i < keys.length; i++) {
    var delta = Number(curr[keys[i]]) - Number(prev[keys[i]])
    if (!isFinite(delta) || delta < 0) return null
    total += delta
  }
  if (total <= 0) return null
  var idle = curr.idle - prev.idle + curr.iowait - prev.iowait
  return Math.max(0, Math.min(100, (total - idle) / total * 100))
}

function parseLoadLine(raw) {
  var n = Number(String(raw || "").split("\t")[1])
  return isFinite(n) ? n : 0
}

function parseGpuLine(raw) {
  var line = String(raw || "").trim().split(/\r?\n/)[0].trim()
  if (!line) return null
  var parts = line.split(/,\s*/)
  if (parts.length < 4) return null
  var utilization = Number(parts[0])
  if (!isFinite(utilization)) return null
  function optional(index) {
    var rawValue = String(parts[index]).trim()
    var value = Number(rawValue)
    return rawValue && isFinite(value) ? value : null
  }
  return {
    utilization: Math.max(0, Math.min(100, utilization)),
    memUsed: optional(1),
    memTotal: optional(2),
    temp: optional(3)
  }
}

function parseTopProcesses(raw, maxCount) {
  var lines = String(raw || "").split("\n")
  var result = []
  var count = maxCount || 5
  for (var i = 0; i < lines.length && result.length < count; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var match = line.match(/^(\d+)\s+(.+?)\s+([+-]?(?:\d+\.?\d*|\.\d+))\s+([+-]?(?:\d+\.?\d*|\.\d+))$/)
    if (!match) continue
    result.push({
      pid: match[1],
      name: match[2],
      cpu: Number(match[3]),
      mem: Number(match[4])
    })
  }
  return result
}

function formatBytes(gb) {
  var n = Number(gb)
  if (!isFinite(n)) return "—"
  if (n < 1) return Math.round(n * 1024) + " MB"
  return n.toFixed(1) + " GB"
}

// --- Network speed parsing ---
// Reads /proc/net/dev and returns per-interface rx/tx bytes.
// Caller computes delta between two reads to get speed.

function parseNetDev(raw) {
  var lines = String(raw || "").split("\n")
  var result = {}
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var match = line.match(/^(\S+):\s*(.*)$/)
    if (!match) continue
    var iface = match[1]
    // Skip loopback
    if (iface === "lo") continue
    var fields = match[2].trim().split(/\s+/)
    if (fields.length < 9) continue
    result[iface] = {
      rxBytes: Number(fields[0]) || 0,
      txBytes: Number(fields[8]) || 0
    }
  }
  return result
}

function parseDefaultInterface(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = 1; i < lines.length; i++) {
    var fields = lines[i].trim().split(/\s+/)
    if (fields.length < 4 || fields[1] !== "00000000") continue
    var flags = parseInt(fields[3], 16)
    // Require a usable route (R + U flags), not just a stale table entry.
    if (isFinite(flags) && (flags & 0x1) !== 0 && (flags & 0x2) !== 0)
      return fields[0]
  }
  return ""
}

function netSpeed(prev, curr, intervalMs) {
  if (!prev || !curr) return { rx: 0, tx: 0 }
  var seconds = intervalMs / 1000
  if (seconds <= 0) return { rx: 0, tx: 0 }
  var rxDelta = curr.rxBytes - prev.rxBytes
  var txDelta = curr.txBytes - prev.txBytes
  return {
    rx: Math.max(0, rxDelta / seconds),
    tx: Math.max(0, txDelta / seconds)
  }
}

function formatSpeed(bytesPerSec) {
  var n = Number(bytesPerSec)
  if (!isFinite(n) || n < 0) return "0 B/s"
  if (n < 1024) return Math.round(n) + " B/s"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB/s"
  return (n / (1024 * 1024)).toFixed(1) + " MB/s"
}

function isLikelyVirtualInterface(iface) {
  return /^(docker\d*|br-|veth|virbr\d*|tun\d*|tap\d*|wg\d*|tailscale|zt|podman\d*|cni\d*|flannel|kube-)/i.test(String(iface))
}

function pickPrimaryInterface(devs, previous) {
  // Prefer current traffic deltas when available. Cumulative byte counts
  // otherwise select old VPN/container interfaces forever.
  var best = ""
  var bestScore = -1
  var bestPhysical = ""
  var bestPhysicalScore = -1
  for (var iface in devs) {
    if (iface === "lo" || !devs[iface]) continue
    var rx = Number(devs[iface].rxBytes)
    var tx = Number(devs[iface].txBytes)
    if (!isFinite(rx)) rx = 0
    if (!isFinite(tx)) tx = 0
    var score = Math.max(0, rx) + Math.max(0, tx)
    var prior = previous && previous[iface]
    if (prior) {
      var rxDelta = rx - Number(prior.rxBytes)
      var txDelta = tx - Number(prior.txBytes)
      score = Math.max(0, isFinite(rxDelta) ? rxDelta : 0)
        + Math.max(0, isFinite(txDelta) ? txDelta : 0)
    }
    if (score > bestScore) {
      bestScore = score
      best = iface
    }
    if (!isLikelyVirtualInterface(iface) && score > bestPhysicalScore) {
      bestPhysicalScore = score
      bestPhysical = iface
    }
  }
  return bestPhysical || best
}

// --- Disk usage parsing ---
// Parses `df -h --output=target,size,used,avail,pcent` output

function parseDiskUsage(raw, mountFilter) {
  var lines = String(raw || "").split("\n")
  var result = []
  var filter = Array.isArray(mountFilter) ? mountFilter : []
  var seenDevices = {}
  for (var i = 1; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var match = line.match(/^(.+?)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)%\s+(\S+)$/)
    if (!match) continue
    var mount = match[1]
    var source = match[6]
    if (filter.length > 0 && filter.indexOf(mount) === -1) continue
    // Skip pseudo/virtual filesystem mount points
    var skipPrefixes = ["/dev", "/proc", "/sys", "/run", "/var/lib/docker", "/tmp"]
    var skipExact = ["devtmpfs", "tmpfs", "proc", "sysfs", "run", "none", "-"]
    var skip = false
    for (var se = 0; se < skipExact.length; se++) {
      if (mount === skipExact[se]) { skip = true; break }
    }
    if (skip) continue
    for (var sp = 0; sp < skipPrefixes.length; sp++) {
      if (mount.indexOf(skipPrefixes[sp]) === 0 && mount !== "/") { skip = true; break }
    }
    if (skip) continue
    // Skip duplicate devices (btrfs subvolumes share the same device)
    // Always keep "/" and skip other mounts on the same device
    if (source && source !== "-" && source !== "none") {
      if (seenDevices[source]) {
        // Keep "/" over other mounts on the same device
        if (mount === "/") {
          // Remove the previous entry for this device
          for (var r = 0; r < result.length; r++) {
            if (result[r].source === source) { result.splice(r, 1); break }
          }
        } else {
          skip = true
        }
      }
      if (!skip) seenDevices[source] = true
    }
    if (skip) continue
    result.push({
      mount: mount,
      size: match[2],
      used: match[3],
      avail: match[4],
      percent: Math.max(0, Math.min(100, Number(match[5]))),
      source: source
    })
  }
  return result
}

// --- Temperature parsing ---
// Reads thermal zone temps from /sys/class/thermal/

function parseTemp(raw, zoneName) {
  if (!String(raw || "").trim()) return null
  var n = Number(String(raw || "").trim())
  if (!isFinite(n)) return null
  // /sys/class/thermal/thermal_zone*/temp is in millidegrees
  return { name: zoneName, temp: n / 1000 }
}

function parseGpuTemp(raw) {
  if (!String(raw || "").trim()) return null
  var n = Number(String(raw || "").trim())
  if (!isFinite(n)) return null
  return { name: "GPU", temp: n }
}

function batteryPresentation(input) {
  if (!input.ready) return { status: "Loading battery…", power: "", available: false }
  if (!input.present) return { status: "No battery", power: "", available: false }
  var labels = { charging: "Charging", discharging: "Discharging", charged: "Charged",
    empty: "Empty", "pending-charge": "Waiting to charge", "pending-discharge": "Waiting to discharge" }
  var state = input.state
  var result = { status: labels[state] || "Status unknown", power: "Power unavailable", available: true }
  // State is the source of truth for flow direction. UPower versions and
  // clients disagree on EnergyRate's sign, while State is stable. A charged
  // or firmware-held battery is idle even when the meter reports tiny noise.
  if (state === "charged" || state === "pending-charge" || state === "pending-discharge") {
    result.power = "Idle"
    return result
  }
  var raw = input.rate
  if (raw === null || raw === undefined || String(raw).trim() === "" || !isFinite(Number(raw))) return result
  if (state === "charging" || state === "discharging") {
    var magnitude = Math.abs(Number(raw))
    result.power = (magnitude > 0 && magnitude < 0.1 ? "<0.1" : magnitude.toFixed(1))
      + " W " + (state === "charging" ? "in" : "out")
  }
  return result
}

function convertTemperature(celsius, unit) {
  var value = Number(celsius)
  if (!isFinite(value)) return null
  return unit === "fahrenheit" ? value * 9 / 5 + 32 : value
}

if (typeof module !== "undefined") {
  module.exports = {
    batteryPresentation: batteryPresentation,
    parseCpuLine: parseCpuLine,
    cpuPercent: cpuPercent,
    parseMemoryLine: parseMemoryLine,
    parseMemInfo: parseMemInfo,
    parseCpuStat: parseCpuStat,
    cpuSnapshotPercent: cpuSnapshotPercent,
    cpuBreakdown: cpuBreakdown,
    parseLoadLine: parseLoadLine,
    parseGpuLine: parseGpuLine,
    parseTopProcesses: parseTopProcesses,
    formatBytes: formatBytes,
    parseNetDev: parseNetDev,
    netSpeed: netSpeed,
    formatSpeed: formatSpeed,
    pickPrimaryInterface: pickPrimaryInterface,
    parseDefaultInterface: parseDefaultInterface,
    parseDiskUsage: parseDiskUsage,
    parseTemp: parseTemp,
    parseGpuTemp: parseGpuTemp,
    convertTemperature: convertTemperature
  }
}
