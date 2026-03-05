import { sortEventsByEventId } from "./event_id"

export function orderNodeEventsForFlush(events) {
  return sortEventsByEventId(events)
}

