import { test, expect } from "bun:test"
import { createTurboStreamBuffer } from "../../app/javascript/lib/turbo_stream_buffer"

function makeStream({ action = "replace", target = "message_123", html = "<turbo-stream></turbo-stream>" } = {}) {
  return {
    outerHTML: html,
    getAttribute(name) {
      if (name === "action") return action
      if (name === "target") return target
      return null
    },
  }
}

function makeEvent({ stream, onPreventDefault } = {}) {
  return {
    target: stream,
    preventDefault: onPreventDefault || (() => {}),
    detail: {},
  }
}

test("buffers replace streams when target is missing, then flushes once target exists", () => {
  let prevented = false
  const rendered = []

  const existing = new Set()

  const buffer = createTurboStreamBuffer({
    getElementById: (id) => (existing.has(id) ? { id } : null),
    renderStreamMessage: (html) => rendered.push(html),
  })

  const stream = makeStream({ action: "replace", target: "message_abc", html: "<turbo-stream action=\"replace\" target=\"message_abc\"></turbo-stream>" })
  const event = makeEvent({
    stream,
    onPreventDefault: () => {
      prevented = true
    },
  })

  buffer.onBeforeStreamRender(event)

  expect(prevented).toBe(true)
  expect(rendered.length).toBe(0)

  // Later, the placeholder appears.
  existing.add("message_abc")
  buffer.flush()

  expect(rendered).toEqual([stream.outerHTML])
})

test("does not buffer when target exists at render time", () => {
  let prevented = false
  const rendered = []

  const buffer = createTurboStreamBuffer({
    getElementById: () => ({ id: "message_ok" }),
    renderStreamMessage: (html) => rendered.push(html),
  })

  const stream = makeStream({ action: "replace", target: "message_ok", html: "<turbo-stream action=\"replace\" target=\"message_ok\"></turbo-stream>" })
  const event = makeEvent({
    stream,
    onPreventDefault: () => {
      prevented = true
    },
  })

  buffer.onBeforeStreamRender(event)
  buffer.flush()

  expect(prevented).toBe(false)
  expect(rendered.length).toBe(0)
})

test("ignores non-message targets", () => {
  let prevented = false
  const rendered = []

  const buffer = createTurboStreamBuffer({
    getElementById: () => null,
    renderStreamMessage: (html) => rendered.push(html),
  })

  const stream = makeStream({ action: "replace", target: "toast_container", html: "<turbo-stream action=\"replace\" target=\"toast_container\"></turbo-stream>" })
  const event = makeEvent({
    stream,
    onPreventDefault: () => {
      prevented = true
    },
  })

  buffer.onBeforeStreamRender(event)
  buffer.flush()

  expect(prevented).toBe(false)
  expect(rendered.length).toBe(0)
})
