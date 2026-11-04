// Pure helpers shared by the policy and sampling cards.
function interval(base, multiplier) {
  var ms = Number(base)
  var scale = Number(multiplier)
  if (!isFinite(ms) || ms <= 0) ms = 1000
  if (!isFinite(scale) || scale < 1) scale = 1
  return Math.min(2147483647, Math.max(1, Math.round(ms * scale)))
}

function lockState(raw) {
  var value = String(raw || "").trim()
  return value === "true" ? true : value === "false" ? false : null
}

// null means unavailable: callers retain the last successful observation.
function displayState(raw, screenName) {
  var monitors
  try { monitors = JSON.parse(String(raw || "")) } catch (_) { return null }
  if (!Array.isArray(monitors)) return null
  if (screenName) {
    monitors = monitors.filter(function(m) { return m && m.name === screenName })
    if (!monitors.length) return null
  }
  if (!monitors.length) return false
  var unknown = false
  for (var i = 0; i < monitors.length; i++) {
    var monitor = monitors[i]
    if (!monitor || typeof monitor.dpmsStatus !== "boolean") { unknown = true; continue }
    if (monitor.disabled === true) continue
    if (monitor.dpmsStatus) return true
  }
  return unknown ? null : false
}

function profileName(profile, saver, balanced, performance) {
  if (profile === saver) return "power-saver"
  if (profile === balanced) return "balanced"
  if (profile === performance) return "performance"
  return ""
}

if (typeof module !== "undefined") module.exports = { interval: interval,
  lockState: lockState, displayState: displayState, profileName: profileName }
