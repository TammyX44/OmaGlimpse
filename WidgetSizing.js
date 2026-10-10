// Auto preserves each card's natural footprint; manual heights never crop content.
function cardHeight(requested, natural) {
  var floor = Number(natural)
  floor = isFinite(floor) ? Math.max(0, floor) : 0
  if (typeof requested !== "number" && typeof requested !== "string") return floor
  var value = Number(requested)
  if (!isFinite(value) || value === 0) return floor
  return Math.max(floor, Math.round(Math.max(80, Math.min(1000, value))))
}

if (typeof module !== "undefined") module.exports = { cardHeight: cardHeight }
