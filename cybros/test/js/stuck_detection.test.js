import { describe, expect, test } from "bun:test"
import { shouldShowStuckWarning } from "../../app/javascript/lib/stuck_detection"

describe("shouldShowStuckWarning", () => {
  test("returns false when no active node event timestamp exists", () => {
    expect(shouldShowStuckWarning({ lastEventAtMs: null, nowMs: 10_000, thresholdSeconds: 30 })).toBe(false)
  })

  test("returns false when elapsed is below threshold", () => {
    expect(shouldShowStuckWarning({ lastEventAtMs: 0, nowMs: 29_999, thresholdSeconds: 30 })).toBe(false)
  })

  test("returns true when elapsed meets/exceeds threshold", () => {
    expect(shouldShowStuckWarning({ lastEventAtMs: 0, nowMs: 30_000, thresholdSeconds: 30 })).toBe(true)
    expect(shouldShowStuckWarning({ lastEventAtMs: 0, nowMs: 45_000, thresholdSeconds: 30 })).toBe(true)
  })
})

