// Layout-only snapshots keep telemetry, colors and GPU preferences independent.
var fields = ["enabled", "x", "y", "cardWidth", "gaugeDiameter"]
var ids = ["systemMonitor", "battery", "media", "topProcesses", "networkSpeed", "diskUsage", "temperature"]

function clone(value) { return JSON.parse(JSON.stringify(value)) }
function safeName(value) { return String(value || "").replace(/[\x00-\x1f\x7f]/g, "").trim().slice(0, 48) }
function own(obj, key) { return Object.prototype.hasOwnProperty.call(obj || {}, key) }
function snapshot(config) {
  var widgets = {}
  ids.forEach(function(id) {
    var src = (config.widgets || {})[id] || {}, dest = {}
    fields.forEach(function(key) { if (own(src, key)) dest[key] = src[key] })
    widgets[id] = dest
  })
  return { widgets: widgets, cardSpacing: Number((config.global || {}).cardSpacing) || 0 }
}
function apply(config, saved) {
  var next = clone(config)
  if (!saved || !saved.widgets) return next
  ids.forEach(function(id) {
    var src = saved.widgets[id]
    if (!src || !next.widgets[id]) return
    fields.forEach(function(key) {
      if (!own(src, key)) return
      var v = src[key]
      if (key === "enabled") { if (typeof v === "boolean") next.widgets[id][key] = v; return }
      if (typeof v !== "number" || !isFinite(v)) return
      if (key === "x" || key === "y") v = v < 0 ? -1 : Math.round(Math.min(100000, v))
      if (key === "cardWidth") v = v === 0 ? 0 : Math.max(200, Math.min(500, v))
      if (key === "gaugeDiameter") v = Math.max(60, Math.min(id === "battery" ? 100 : 160, v))
      next.widgets[id][key] = v
    })
  })
  if (typeof saved.cardSpacing === "number" && isFinite(saved.cardSpacing))
    next.global.cardSpacing = Math.max(0, Math.min(24, saved.cardSpacing))
  return next
}
function topologyKey(screens) {
  return JSON.stringify(screens.map(function(s) {
    return [String(s.name), Number(s.width), Number(s.height), Number(s.scale) || 1, Number(s.x) || 0, Number(s.y) || 0]
  }).sort(function(a, b) { return a[0].localeCompare(b[0]) }))
}
function profileKey(screens, target) { return topologyKey(screens) + "|" + String(target || "") }
function remember(config, key) {
  if (!key) return config
  var next = clone(config)
  if (!next.monitorLayouts || typeof next.monitorLayouts !== "object") next.monitorLayouts = {}
  // Keys come from screen metadata, not user-supplied object property names.
  next.monitorLayouts[key] = snapshot(config)
  return next
}
function switchProfile(config, oldKey, newKey) {
  var next = remember(config, oldKey)
  if (own(next.monitorLayouts, newKey)) next = apply(next, next.monitorLayouts[newKey])
  // A new setup starts with the current arrangement; visual clamping never
  // writes back into the old setup's saved positions.
  next = remember(next, newKey)
  return next
}
function named(config, name, action) {
  name = safeName(name)
  if (!name || ["__proto__", "constructor", "prototype"].indexOf(name) !== -1) return config
  var next = clone(config)
  if (!next.namedLayouts || typeof next.namedLayouts !== "object") next.namedLayouts = {}
  if (action === "save") next.namedLayouts[name] = snapshot(config)
  else if (action === "delete") delete next.namedLayouts[name]
  else if (action === "load" && own(next.namedLayouts, name)) next = apply(next, next.namedLayouts[name])
  return next
}

if (typeof module !== "undefined") module.exports = { snapshot: snapshot, apply: apply, topologyKey: topologyKey,
  profileKey: profileKey, remember: remember, switchProfile: switchProfile, named: named, safeName: safeName }
