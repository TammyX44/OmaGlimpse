// One-time repair for saved stacks affected by the taller GPU carousel.
// Keep horizontal placement; only push affected manual cards downward.
function overlaps(a, b, gap) {
  return !(a.x + a.width + gap <= b.x || b.x + b.width + gap <= a.x
    || a.y + a.height + gap <= b.y || b.y + b.height + gap <= a.y)
}

function repairGpuStack(rects, gap, bottomLimit) {
  var monitor = rects.filter(function(rect) { return rect.widgetId === "systemMonitor" })[0]
  if (!monitor) return { moves: [], blocked: false }
  gap = Math.max(0, Number(gap) || 0)
  var manual = rects.filter(function(rect) {
    return rect.manual && rect.widgetId !== monitor.widgetId && rect.y >= monitor.y
  }).sort(function(a, b) { return a.y - b.y || a.x - b.x || a.widgetId.localeCompare(b.widgetId) })
  var settled = rects.filter(function(rect) { return manual.indexOf(rect) === -1 })
  var changed = [monitor], moves = [], blocked = false

  manual.forEach(function(rect) {
    var affected = changed.some(function(other) { return overlaps(rect, other, gap) })
    var placed = rect
    if (affected) {
      var next = { widgetId: rect.widgetId, x: rect.x, y: rect.y,
        width: rect.width, height: rect.height, manual: true }
      for (var pass = 0; pass <= settled.length; pass++) {
        var y = next.y
        settled.forEach(function(other) {
          if (overlaps(next, other, gap)) y = Math.max(y, Math.ceil(other.y + other.height + gap))
        })
        if (y === next.y) break
        next.y = y
      }
      if (next.y + next.height <= bottomLimit) {
        placed = next
        moves.push({ widgetId: rect.widgetId, y: next.y })
        changed.push(next)
      } else blocked = true
    }
    settled.push(placed)
  })
  return { moves: moves, blocked: blocked }
}

if (typeof module !== "undefined") module.exports = { repairGpuStack: repairGpuStack }
