import { describe, expect, test } from "bun:test"
import { orderNodeEventsForFlush } from "../../app/javascript/lib/node_event_ordering"

describe("orderNodeEventsForFlush", () => {
  test("orders buffered node events by event_id ascending", () => {
    const events = [
      { event_id: "3", kind: "output_delta", text: "C" },
      { event_id: "1", kind: "output_delta", text: "A" },
      { event_id: "2", kind: "output_delta", text: "B" },
    ]

    const ordered = orderNodeEventsForFlush(events)
    expect(ordered.map((e) => e.event_id)).toEqual(["1", "2", "3"])
  })
})

