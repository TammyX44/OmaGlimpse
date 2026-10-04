// Config load/save/merge helpers for the desktop widgets plugin.
// Config lives at ~/.config/omarchy/tammy-widgets.json and is hot-reloaded
// via FileView in Widgets.qml.

var CONFIG_PATH = Quickshell.env("HOME") + "/.config/omarchy/tammy-widgets.json"

function defaultConfig() {
  return {
    version: 3,
    gpuLayoutRevision: 1,
    themeMode: "theme",
    colors: {
      accent: "",
      cardBackground: "",
      cardOpacity: 0.55,
      borderColor: "",
      borderOpacity: 0.15,
      textColor: ""
    },
    global: {
      cardRadius: 18,
      gaugeDiameter: 110,
      cardSpacing: 12,
      blurEnabled: true,
      blurIntensity: 50,
      gaugeColorMode: "semantic"
    },
    widgets: {
      systemMonitor: {
        enabled: true,
        x: -1,
        y: -1,
        refreshInterval: 3000,
        showGpu: true,
        showCpu: true,
        showRam: true,
        gpuDevice: "",
        gpuAliases: {},
        cardWidth: 0,
        gaugeDiameter: 110
      },
      battery: {
        enabled: true,
        x: -1,
        y: -1,
        refreshInterval: 10000,
        showProfiles: true,
        showPower: true,
        cardWidth: 0,
        gaugeDiameter: 94
      },
      media: {
        enabled: true,
        x: -1,
        y: -1,
        refreshInterval: 3000,
        showAlbumArt: true,
        showControls: true,
        cardWidth: 0
      },
      topProcesses: {
        enabled: true,
        x: -1,
        y: -1,
        refreshInterval: 3000,
        processCount: 5,
        sortBy: "cpu",
        cardWidth: 0
      },
      networkSpeed: {
        enabled: false,
        x: -1,
        y: -1,
        refreshInterval: 1000,
        interface: "auto",
        cardWidth: 0,
        gaugeDiameter: 110
      },
      diskUsage: {
        enabled: false,
        x: -1,
        y: -1,
        refreshInterval: 30000,
        mounts: [],
        cardWidth: 0
      },
      temperature: {
        enabled: false,
        x: -1,
        y: -1,
        refreshInterval: 5000,
        sensors: ["cpu", "gpu"],
        showFan: true,
        unit: "celsius",
        fanMaxRpm: 5000,
        cardWidth: 0
      }
    }
  }
}

function plainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function deepMerge(base, override) {
  if (override === null || override === undefined) return base
  if (!plainObject(override)) return override
  var out = {}
  if (plainObject(base)) {
    for (var k in base) {
      if (Object.prototype.hasOwnProperty.call(base, k) && k !== "__proto__" && k !== "constructor" && k !== "prototype")
        out[k] = base[k]
    }
  }
  for (var key in override) {
    if (!Object.prototype.hasOwnProperty.call(override, key) || key === "__proto__" || key === "constructor" || key === "prototype") continue
    out[key] = plainObject(override[key]) ? deepMerge(out[key], override[key]) : override[key]
  }
  return out
}

function bounded(value, fallback, minimum, maximum) {
  if (value === null || value === undefined || String(value).trim() === "") return fallback
  var n = Number(value)
  return isFinite(n) ? Math.max(minimum, Math.min(maximum, n)) : fallback
}

function parseConfigResult(raw) {
  try {
    var cfg = parseConfig(raw)
    return { ok: true, config: cfg, error: "" }
  } catch (error) {
    return { ok: false, config: null, error: "Invalid widget settings: " + error.message }
  }
}

function parseConfig(raw) {
  var trimmed = String(raw || "").trim()
  var saved = trimmed ? JSON.parse(trimmed) : {}
  if (!plainObject(saved)) throw new Error("Expected an object")
  var sections = ["global", "colors", "widgets"]
  for (var s = 0; s < sections.length; s++) {
    if (saved[sections[s]] !== undefined && !plainObject(saved[sections[s]]))
      throw new Error("Invalid " + sections[s] + " section")
  }
  if (saved.widgets) {
    for (var id in saved.widgets) {
      if (allWidgetIds().indexOf(id) !== -1 && !plainObject(saved.widgets[id]))
        throw new Error("Invalid widget " + id)
    }
  }
  var cfg = deepMerge({}, saved)

  // --- Migration: move stale top-level keys into config.global ---
  // Older versions of updateGlobalConfig wrote blurEnabled, blurIntensity,
  // and gaugeColorMode to the top level instead of config.global.
  // Migrate them so there's one source of truth.
  var migrateKeys = ["blurEnabled", "blurIntensity", "gaugeColorMode",
                     "cardRadius", "gaugeDiameter", "cardSpacing"]
  for (var i = 0; i < migrateKeys.length; i++) {
    var k = migrateKeys[i]
    if (cfg[k] !== undefined) {
      if (!cfg.global) cfg.global = {}
      if (cfg.global[k] === undefined) cfg.global[k] = cfg[k]
      delete cfg[k]
    }
  }

  // --- Migration: remove widgets that no longer exist in code ---
  var validIds = allWidgetIds()
  if (cfg.widgets) {
    for (var wid in cfg.widgets) {
      if (validIds.indexOf(wid) === -1) delete cfg.widgets[wid]
    }
  }

  var defaults = defaultConfig()
  cfg = deepMerge(defaults, cfg)
  // Older saved positions predate the extra GPU labels. Repair them once,
  // after the rendered card sizes are available, rather than guessing here.
  cfg.gpuLayoutRevision = !trimmed || saved.gpuLayoutRevision === 1 ? 1 : 0
  cfg.global.cardRadius = bounded(cfg.global.cardRadius, 18, 0, 30)
  cfg.global.cardSpacing = bounded(cfg.global.cardSpacing, 12, 0, 24)
  cfg.global.gaugeDiameter = bounded(cfg.global.gaugeDiameter, 110, 60, 160)
  cfg.global.blurIntensity = bounded(cfg.global.blurIntensity, 50, 0, 100)
  cfg.global.blurEnabled = typeof cfg.global.blurEnabled === "boolean" ? cfg.global.blurEnabled : true
  cfg.global.gaugeColorMode = cfg.global.gaugeColorMode === "accent" ? "accent" : "semantic"
  cfg.themeMode = cfg.themeMode === "custom" ? "custom" : "theme"
  cfg.colors.cardOpacity = bounded(cfg.colors.cardOpacity, 0.55, 0, 1)
  cfg.colors.borderOpacity = bounded(cfg.colors.borderOpacity, 0.15, 0, 1)
  for (var w = 0; w < validIds.length; w++) {
    var wid = validIds[w]
    var widget = cfg.widgets[wid]
    var fallback = defaults.widgets[wid]
    for (var key in fallback) {
      if (typeof fallback[key] === "boolean" && typeof widget[key] !== "boolean") widget[key] = fallback[key]
    }
    widget.cardWidth = Number(widget.cardWidth) === 0 ? 0 : bounded(widget.cardWidth, 0, 200, 500)
    widget.refreshInterval = bounded(widget.refreshInterval, fallback.refreshInterval, 500, 30000)
    if (widget.gaugeDiameter !== undefined) {
      var maxGauge = wid === "battery" ? 100 : 160
      widget.gaugeDiameter = bounded(widget.gaugeDiameter, fallback.gaugeDiameter || 110, 60, maxGauge)
    }
    if (widget.cardOpacity !== undefined) widget.cardOpacity = bounded(widget.cardOpacity, 1, 0.1, 1)
    widget.clickThrough = widget.clickThrough === true
    widget.x = coordinateOrAuto(widget.x)
    widget.y = coordinateOrAuto(widget.y)
    if (["auto", "semantic", "accent"].indexOf(widget.gaugeColorMode) === -1) widget.gaugeColorMode = "auto"
  }
  cfg.widgets.temperature.sensors = Array.isArray(cfg.widgets.temperature.sensors)
    ? cfg.widgets.temperature.sensors.filter(function(sensor) { return sensor === "cpu" || sensor === "gpu" }) : ["cpu", "gpu"]
  cfg.widgets.temperature.unit = cfg.widgets.temperature.unit === "fahrenheit"
    ? "fahrenheit" : "celsius"
  var monitor = cfg.widgets.systemMonitor
  monitor.gpuDevice = typeof monitor.gpuDevice === "string"
    && /^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/i.test(monitor.gpuDevice)
      ? monitor.gpuDevice.toLowerCase() : ""
  var aliases = {}
  if (plainObject(monitor.gpuAliases)) {
    Object.keys(monitor.gpuAliases).slice(0, 64).forEach(function(id) {
      if (/^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/i.test(id)
          && typeof monitor.gpuAliases[id] === "string")
        aliases[id.toLowerCase()] = monitor.gpuAliases[id].replace(/[\x00-\x1f\x7f]/g, "").trim().slice(0, 64)
    })
  }
  monitor.gpuAliases = aliases
  cfg.widgets.diskUsage.mounts = Array.isArray(cfg.widgets.diskUsage.mounts)
    ? cfg.widgets.diskUsage.mounts.filter(function(mount) { return typeof mount === "string" && mount.charAt(0) === "/" }) : []
  return cfg
}

function widgetConfig(config, widgetId) {
  if (!config || !config.widgets || !config.widgets[widgetId]) return null
  return config.widgets[widgetId]
}

function widgetEnabled(config, widgetId) {
  var w = widgetConfig(config, widgetId)
  return !!(w && w.enabled)
}

function coordinateOrAuto(value) {
  if (value === null || value === undefined || String(value).trim() === "") return -1
  var n = Number(value)
  return isFinite(n) ? n : -1
}

function widgetX(config, widgetId) {
  var w = widgetConfig(config, widgetId)
  return w ? coordinateOrAuto(w.x) : -1
}

function widgetY(config, widgetId) {
  var w = widgetConfig(config, widgetId)
  return w ? coordinateOrAuto(w.y) : -1
}

function widgetRefreshInterval(config, widgetId) {
  var w = widgetConfig(config, widgetId)
  if (!w || w.refreshInterval === null || w.refreshInterval === undefined
      || w.refreshInterval === "") return 2000
  var value = Number(w.refreshInterval)
  return isFinite(value) ? Math.max(500, value) : 2000
}

function widgetCardOpacity(config, widgetId) {
  var w = widgetConfig(config, widgetId)
  if (!w) return 1.0
  var v = Number(w.cardOpacity)
  return isFinite(v) ? Math.max(0.1, Math.min(1.0, v)) : 1.0
}

function widgetClickThrough(config, widgetId) {
  var w = widgetConfig(config, widgetId)
  return !!(w && w.clickThrough)
}

function allWidgetIds() {
  return ["systemMonitor", "battery", "media", "topProcesses",
          "networkSpeed", "diskUsage", "temperature"]
}

function widgetDisplayName(id) {
  var names = {
    systemMonitor: "System Monitor",
    battery: "Battery & Power",
    media: "Media Player",
    topProcesses: "Top Processes",
    networkSpeed: "Network Speed",
    diskUsage: "Disk Usage",
    temperature: "Temperature"
  }
  return names[id] || id
}

function enabledWidgetIds(config) {
  var ids = allWidgetIds()
  var out = []
  for (var i = 0; i < ids.length; i++) {
    if (widgetEnabled(config, ids[i])) out.push(ids[i])
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    CONFIG_PATH: CONFIG_PATH,
    defaultConfig: defaultConfig,
    deepMerge: deepMerge,
    parseConfig: parseConfig,
    parseConfigResult: parseConfigResult,
    widgetConfig: widgetConfig,
    widgetEnabled: widgetEnabled,
    widgetX: widgetX,
    widgetY: widgetY,
    widgetRefreshInterval: widgetRefreshInterval,
    widgetCardOpacity: widgetCardOpacity,
    widgetClickThrough: widgetClickThrough,
    allWidgetIds: allWidgetIds,
    widgetDisplayName: widgetDisplayName,
    enabledWidgetIds: enabledWidgetIds
  }
}
