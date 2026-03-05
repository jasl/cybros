export function shouldShowStuckWarning({ lastEventAtMs, nowMs, thresholdSeconds }) {
  const last = Number(lastEventAtMs)
  const now = Number(nowMs)
  const threshold = Number(thresholdSeconds)

  if (!Number.isFinite(last)) return false
  if (!Number.isFinite(now)) return false
  if (!Number.isFinite(threshold) || threshold <= 0) return false

  const elapsedSeconds = (now - last) / 1000
  return elapsedSeconds >= threshold
}

