// Rates are bytes/second; timestamps are milliseconds. No animation clock.
var windowMs = 60000
var maxSamples = 120
var minimumScale = 64 * 1024

function rate(value) {
  return isFinite(value) ? Math.max(0, Number(value)) : 0
}

function fixedScale(limit) {
  var value = Number(limit)
  return (isFinite(value) && value > 0 ? value : 5) * 1024 * 1024
}

function nextScale(previous, rx, tx, elapsedMs) {
  var target = Math.max(minimumScale, rate(rx) * 1.2, rate(tx) * 1.2)
  var old = Math.max(minimumScale, rate(previous))
  // Rise immediately; decay with a 15-second time constant.
  return target >= old ? target : Math.max(target,
    old * Math.exp(-rate(elapsedMs) / 15000))
}

function append(history, timestamp, rx, tx, gap) {
  var result = history.filter(function(point) {
    return point.time >= timestamp - windowMs && point.time < timestamp
  })
  result.push({ time: timestamp, rx: rate(rx), tx: rate(tx), gap: !!gap })
  return result.slice(-maxSamples)
}

function segments(history, channel, now, width, height, scale, maxGapMs) {
  if (!(scale > 0) || !isFinite(scale)) return []
  var lines = [], line = []
  var previous = null
  history.forEach(function(point) {
    if (point.gap || point.time < now - windowMs ||
        (previous !== null && point.time - previous > maxGapMs)) {
      if (line.length > 1) lines.push(line)
      line = []
    }
    if (!point.gap && point.time >= now - windowMs && point.time <= now) {
      line.push({ x: width * (1 - (now - point.time) / windowMs),
        y: height * (1 - Math.min(1, point[channel] / scale)) })
    }
    previous = point.time
  })
  if (line.length > 1) lines.push(line)
  return lines
}

if (typeof module !== "undefined") module.exports = {
  fixedScale: fixedScale, nextScale: nextScale, append: append,
  segments: segments, windowMs: windowMs, maxSamples: maxSamples,
  minimumScale: minimumScale
}
