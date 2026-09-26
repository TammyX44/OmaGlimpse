// Color resolution helpers: theme-following or custom overrides.
// When themeMode === "theme", colors come from the Color singleton
// (which reads the active Omarchy theme's colors.toml + shell.toml).
// When themeMode === "custom", user-specified hex colors from config win.

function normalizeHex(hex) {
  var s = String(hex === null || hex === undefined ? "" : hex).trim()
  return /^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/.test(s) ? s : ""
}

function hexToColor(hex) {
  var s = normalizeHex(hex)
  if (!s) return null
  var h = s.match(/^#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?$/)
  if (!h) return null
  return Qt.rgba(
    parseInt(h[1].substr(0, 2), 16) / 255,
    parseInt(h[1].substr(2, 2), 16) / 255,
    parseInt(h[1].substr(4, 2), 16) / 255,
    h[2] ? parseInt(h[2], 16) / 255 : 1)
}

function resolveAccent(config) {
  if (config && config.themeMode === "custom") {
    var c = hexToColor(config.colors && config.colors.accent)
    if (c) return c
  }
  return Color.accent
}

function resolveTextColor(config) {
  if (config && config.themeMode === "custom") {
    var c = hexToColor(config.colors && config.colors.textColor)
    if (c) return c
  }
  return Color.foreground
}

function resolveCardColor(config) {
  var opacity = config && config.colors ? Number(config.colors.cardOpacity) : 0.92
  if (!isFinite(opacity)) opacity = 0.92
  opacity = Math.max(0, Math.min(1, opacity))

  // When liquid glass blur is enabled, the blur intensity slider
  // controls how much blur shows through by reducing card opacity.
  // blurIntensity 0  → opacity unchanged (user's cardOpacity setting)
  // blurIntensity 50 → opacity reduced toward 0.55
  // blurIntensity 100 → opacity reduced toward 0.25
  if (config && config.global && config.global.blurEnabled !== false) {
    var blur = Number(config.global.blurIntensity)
    if (isFinite(blur) && blur > 0) {
      var minOpacity = 0.25
      opacity = opacity - (opacity - minOpacity) * (blur / 100)
      opacity = Math.max(minOpacity, Math.min(1, opacity))
    }
  }

  if (config && config.themeMode === "custom") {
    var c = hexToColor(config.colors && config.colors.cardBackground)
    if (c) return Qt.rgba(c.r, c.g, c.b, opacity)
  }

  // Theme mode: use background color with opacity
  var bg = Color.background
  return Qt.rgba(bg.r, bg.g, bg.b, opacity)
}

function resolveBorderColor(config) {
  var opacity = config && config.colors ? Number(config.colors.borderOpacity) : 0.12
  if (!isFinite(opacity)) opacity = 0.12
  opacity = Math.max(0, Math.min(1, opacity))

  if (config && config.themeMode === "custom") {
    var c = hexToColor(config.colors && config.colors.borderColor)
    if (c) return Qt.rgba(c.r, c.g, c.b, opacity)
  }

  // Theme mode: use foreground with low opacity
  var fg = Color.foreground
  return Qt.rgba(fg.r, fg.g, fg.b, opacity)
}

function resolveTrackColor(config) {
  // Gauge track ring — always a dim version of foreground
  var fg = Color.foreground
  return Qt.rgba(fg.r, fg.g, fg.b, 0.10)
}

function resolveTempColor(temp) {
  // Semantic temperature colors: green=cool, yellow=warm, orange=hot, red=critical
  if (temp >= 85) return Color.urgent
  if (temp >= 70) return "#e0af68"  // yellow
  if (temp >= 55) return "#db9d4f"  // orange
  return "#9ece6a"                  // green
}

function resolveTempStatus(temp) {
  if (temp >= 85) return "Critical"
  if (temp >= 70) return "Hot"
  if (temp >= 55) return "Warm"
  return "Cool"
}

// Semantic resource color: green=low, yellow=moderate, orange=high, red=critical
function resolveLoadColor(percent) {
  if (percent >= 90) return Color.urgent
  if (percent >= 75) return "#db9d4f"  // orange
  if (percent >= 50) return "#e0af68"  // yellow
  return "#9ece6a"                     // green
}

// Semantic battery color: green=good, yellow=low, red=critical
function resolveBatteryColor(percent, charging) {
  if (charging) return "#9ece6a"       // green when charging
  if (percent < 15) return Color.urgent
  if (percent < 30) return "#db9d4f"   // orange
  return "#9ece6a"                     // green
}

// Resolve gauge color mode: per-widget overrides global. "auto" = use global.
function resolveGaugeMode(config, widgetId) {
  if (config && config.widgets && config.widgets[widgetId] && config.widgets[widgetId].gaugeColorMode
      && config.widgets[widgetId].gaugeColorMode !== "auto")
    return config.widgets[widgetId].gaugeColorMode
  if (config && config.global && config.global.gaugeColorMode)
    return config.global.gaugeColorMode
  return "semantic"
}

// Resolve gauge color: semantic (green/yellow/red) or theme accent
function resolveGaugeColor(config, widgetId, percent, accentColor) {
  if (resolveGaugeMode(config, widgetId) === "accent") return accentColor
  return resolveLoadColor(percent)
}

// Resolve battery gauge color: semantic or theme accent
function resolveBatteryGaugeColor(config, widgetId, percent, charging, accentColor) {
  if (resolveGaugeMode(config, widgetId) === "accent") return accentColor
  return resolveBatteryColor(percent, charging)
}

// Resolve temperature gauge color: semantic or theme accent
function resolveTempGaugeColor(config, widgetId, temp, accentColor) {
  if (resolveGaugeMode(config, widgetId) === "accent") return accentColor
  return resolveTempColor(temp)
}
function resolveMutedColor(textColor) {
  return Qt.rgba(textColor.r, textColor.g, textColor.b, 0.60)
}

// Very muted text for secondary info (45% opacity)
function resolveDimColor(textColor) {
  return Qt.rgba(textColor.r, textColor.g, textColor.b, 0.45)
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeHex: normalizeHex,
    hexToColor: hexToColor,
    resolveAccent: resolveAccent,
    resolveTextColor: resolveTextColor,
    resolveCardColor: resolveCardColor,
    resolveBorderColor: resolveBorderColor,
    resolveTrackColor: resolveTrackColor,
    resolveTempColor: resolveTempColor,
    resolveTempStatus: resolveTempStatus,
    resolveLoadColor: resolveLoadColor,
    resolveBatteryColor: resolveBatteryColor,
    resolveGaugeColor: resolveGaugeColor,
    resolveBatteryGaugeColor: resolveBatteryGaugeColor,
    resolveTempGaugeColor: resolveTempGaugeColor,
    resolveMutedColor: resolveMutedColor,
    resolveDimColor: resolveDimColor
  }
}
