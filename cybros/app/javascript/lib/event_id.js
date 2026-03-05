export function compareEventIds(a, b) {
  const aStr = String(a || "")
  const bStr = String(b || "")
  if (!aStr && !bStr) return 0
  if (!aStr) return -1
  if (!bStr) return 1

  if (/^\d+$/.test(aStr) && /^\d+$/.test(bStr)) {
    const aInt = BigInt(aStr)
    const bInt = BigInt(bStr)
    if (aInt < bInt) return -1
    if (aInt > bInt) return 1
    return 0
  }

  return aStr.localeCompare(bStr)
}

export function sortEventsByEventId(events) {
  return Array.from(events || []).sort((x, y) => compareEventIds(x?.event_id, y?.event_id))
}

export function boundedPush(array, item, maxLen) {
  const out = Array.isArray(array) ? array : []
  out.push(item)
  const max = Number(maxLen || 0)
  if (Number.isFinite(max) && max > 0 && out.length > max) {
    out.splice(0, out.length - max)
  }
  return out
}
