import { test, expect } from "bun:test"
import {
  createTurboStreamBuffer,
  installTurboStreamBuffer,
  mutationCouldRevealBufferedTarget,
  resolveTurboStreamBufferScopeRoot,
} from "../../app/javascript/lib/turbo_stream_buffer"

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

test("mutationCouldRevealBufferedTarget returns true only when message_* wrappers may have been added", () => {
  const makeMutation = (addedNodes) => ({ addedNodes })

  expect(mutationCouldRevealBufferedTarget([])).toBe(false)

  expect(mutationCouldRevealBufferedTarget([makeMutation([])])).toBe(false)

  expect(
    mutationCouldRevealBufferedTarget([
      makeMutation([{ id: "toast_container", querySelectorAll: () => [] }]),
    ]),
  ).toBe(false)

  expect(
    mutationCouldRevealBufferedTarget([
      makeMutation([{ id: "message_abc", querySelectorAll: () => [] }]),
    ]),
  ).toBe(true)

  expect(
    mutationCouldRevealBufferedTarget([
      makeMutation([{ id: "wrapper", querySelectorAll: () => [{ id: "message_nested" }] }]),
    ]),
  ).toBe(true)
})

test("resolveTurboStreamBufferScopeRoot prefers an explicit scope element when present", () => {
  const scopeEl = { id: "scope_el" }
  const bodyEl = { id: "body_el" }
  const htmlEl = { id: "html_el" }

  const doc = {
    querySelector: (sel) => (sel === "[data-turbo-stream-buffer-scope]" ? scopeEl : null),
    body: bodyEl,
    documentElement: htmlEl,
  }

  expect(resolveTurboStreamBufferScopeRoot({ documentLike: doc })).toBe(scopeEl)
})

test("resolveTurboStreamBufferScopeRoot falls back to body/documentElement when no explicit scope exists", () => {
  const bodyEl = { id: "body_el" }
  const htmlEl = { id: "html_el" }

  const doc = {
    querySelector: () => null,
    body: bodyEl,
    documentElement: htmlEl,
  }

  expect(resolveTurboStreamBufferScopeRoot({ documentLike: doc })).toBe(bodyEl)
})

test("installTurboStreamBuffer rebinds observer to explicit scope on turbo:load", () => {
  let scopeEl = null

  const bodyEl = { id: "body_el" }
  const explicitEl = { id: "explicit_el" }

  const listeners = new Map()
  const doc = {
    querySelector: (sel) => (sel === "[data-turbo-stream-buffer-scope]" ? scopeEl : null),
    body: bodyEl,
    documentElement: { id: "html_el" },
    getElementById: () => null,
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name, fn) => {
      if (listeners.get(name) === fn) listeners.delete(name)
    },
  }

  const observed = []
  class FakeMutationObserver {
    constructor(_cb) {}
    observe(root) {
      observed.push(root)
    }
    disconnect() {
      observed.push("disconnect")
    }
  }

  const turbo = { renderStreamMessage: () => {} }

  // Initially, explicit scope doesn't exist: should observe body.
  scopeEl = null
  const handle = installTurboStreamBuffer({
    turbo,
    documentLike: doc,
    MutationObserverClass: FakeMutationObserver,
    scopeRoot: resolveTurboStreamBufferScopeRoot,
  })

  expect(observed).toContain(bodyEl)

  // Later (Turbo navigation complete), explicit container exists: should re-observe explicit.
  scopeEl = explicitEl
  listeners.get("turbo:load")?.()

  expect(observed).toContain(explicitEl)

  handle?.uninstall?.()
})
