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

// Snap in logical pixels, so fractional display scaling does not change the
// perceived grid. Card edges/centres and the configured gap take priority.
function snapPosition(rect, others, bounds, options) {
  var x = rect.x, y = rect.y, guideX = -1, guideY = -1
  var grid = Math.max(4, Math.min(64, Number(options.gridSize) || 8))
  var tolerance = 8, dx = tolerance + 1, dy = tolerance + 1
  if (options.snapToGrid) {
    x = Math.round(x / grid) * grid
    y = bounds.top + Math.round((y - bounds.top) / grid) * grid
  }
  if (options.snapToCards) {
    var xs = [{ p: bounds.left, g: bounds.left }, { p: bounds.right - rect.width, g: bounds.right },
      { p: (bounds.left + bounds.right - rect.width) / 2, g: (bounds.left + bounds.right) / 2 }]
    var ys = [{ p: bounds.top, g: bounds.top }, { p: bounds.bottom - rect.height, g: bounds.bottom }]
    var gap = Math.max(0, Number(options.gap) || 0)
    others.forEach(function(o) {
      xs.push({ p: o.x, g: o.x }, { p: o.x + o.width - rect.width, g: o.x + o.width },
        { p: o.x + (o.width - rect.width) / 2, g: o.x + o.width / 2 },
        { p: o.x + o.width + gap, g: o.x + o.width + gap }, { p: o.x - rect.width - gap, g: o.x - gap })
      ys.push({ p: o.y, g: o.y }, { p: o.y + o.height - rect.height, g: o.y + o.height },
        { p: o.y + (o.height - rect.height) / 2, g: o.y + o.height / 2 },
        { p: o.y + o.height + gap, g: o.y + o.height + gap }, { p: o.y - rect.height - gap, g: o.y - gap })
    })
    xs.forEach(function(c) { var d = Math.abs(c.p - rect.x); if (d <= tolerance && d < dx) { x = c.p; guideX = c.g; dx = d } })
    ys.forEach(function(c) { var d = Math.abs(c.p - rect.y); if (d <= tolerance && d < dy) { y = c.p; guideY = c.g; dy = d } })
  }
  var cx = Math.max(bounds.left, Math.min(x, Math.max(bounds.left, bounds.right - rect.width)))
  var cy = Math.max(bounds.top, Math.min(y, Math.max(bounds.top, bounds.bottom - rect.height)))
  return { x: cx, y: cy, guideX: cx === x ? guideX : -1, guideY: cy === y ? guideY : -1 }
}

if (typeof module !== "undefined") module.exports = { repairGpuStack: repairGpuStack, snapPosition: snapPosition }
