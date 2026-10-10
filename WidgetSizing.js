// Manual cards reflow to their compact floor; Auto retains the full footprint.
function requestedHeight(requested) {
  if (typeof requested !== "number" && typeof requested !== "string") return 0
  var value = Number(requested)
  return !isFinite(value) || value === 0 ? 0 : Math.round(Math.max(80, Math.min(1000, value)))
}
function cardHeight(requested, natural, minimum) {
  var floor = Number(natural)
  floor = isFinite(floor) ? Math.max(0, floor) : 0
  var value = requestedHeight(requested)
  if (value === 0) return floor
  var compactFloor = Number(minimum)
  compactFloor = minimum !== undefined && isFinite(compactFloor) ? Math.max(80, compactFloor) : floor
  return Math.max(compactFloor, value)
}

if (typeof module !== "undefined") module.exports = { cardHeight: cardHeight, requestedHeight: requestedHeight }
