import { describe, expect, test } from "bun:test"
import { boundedPush, compareEventIds, sortEventsByEventId } from "../../app/javascript/lib/event_id"

describe("compareEventIds", () => {
  test("handles empty values", () => {
    expect(compareEventIds("", "")).toBe(0)
    expect(compareEventIds("", "1")).toBe(-1)
    expect(compareEventIds("1", "")).toBe(1)
  })

  test("compares numeric strings by integer value", () => {
    expect(compareEventIds("2", "10")).toBe(-1)
    expect(compareEventIds("10", "2")).toBe(1)
    expect(compareEventIds("10", "10")).toBe(0)
  })

  test("falls back to localeCompare for non-numeric", () => {
    expect(compareEventIds("b", "a")).toBe(1)
    expect(compareEventIds("a", "b")).toBe(-1)
  })
})

describe("sortEventsByEventId", () => {
  test("sorts by event_id ascending", () => {
    const events = [
      { event_id: "3", kind: "output_delta" },
      { event_id: "1", kind: "output_delta" },
      { event_id: "2", kind: "output_delta" },
    ]
    const sorted = sortEventsByEventId(events)
    expect(sorted.map((e) => e.event_id)).toEqual(["1", "2", "3"])
  })
})

describe("boundedPush", () => {
  test("keeps only last N items", () => {
    const arr = []
    for (let i = 0; i < 5; i++) boundedPush(arr, i, 3)
    expect(arr).toEqual([2, 3, 4])
  })
})
