import { describe, expect, test } from "bun:test"
import { postAndRenderTurboStream, postAndTurboVisit } from "../../app/javascript/lib/post_and_turbo_visit"

describe("postAndTurboVisit", () => {
  test("preserves scroll for same-url Turbo visits when requested", async () => {
    const listeners = new Map()
    const scrollCalls = []

    const documentLike = {
      querySelector: (selector) =>
        selector === "meta[name='csrf-token']"
          ? { getAttribute: () => "csrf-token" }
          : null,
      addEventListener: (name, fn) => listeners.set(name, fn),
      removeEventListener: (name, fn) => {
        if (listeners.get(name) === fn) listeners.delete(name)
      },
    }

    const windowLike = {
      location: { href: "http://example.test/conversations/1" },
      scrollX: 12,
      scrollY: 345,
      scrollTo: (x, y) => scrollCalls.push([x, y]),
      requestAnimationFrame: (fn) => fn(),
    }

    const visits = []
    const turbo = {
      visit: (url, options) => visits.push([url, options]),
    }

    const fetchImpl = async () => ({ ok: true, url: "http://example.test/conversations/1" })
    globalThis.window = windowLike

    await postAndTurboVisit(
      "/conversations/1/regenerate",
      { agent_node_id: "node_1" },
      { documentLike, turbo, windowLike, preserveScroll: true, fetchImpl },
    )

    expect(visits).toEqual([
      ["http://example.test/conversations/1", { action: "replace" }],
    ])
    expect(scrollCalls).toEqual([])

    listeners.get("turbo:load")?.()

    expect(scrollCalls).toEqual([[12, 345]])
  })

  test("renders turbo streams in place without navigating", async () => {
    const rendered = []
    const documentLike = {
      querySelector: (selector) =>
        selector === "meta[name='csrf-token']"
          ? { getAttribute: () => "csrf-token" }
          : null,
    }

    const fetchImpl = async () => ({
      ok: true,
      text: async () => '<turbo-stream action="replace" target="conversation_123_messages_list"></turbo-stream>',
    })

    const turbo = {
      renderStreamMessage: (html) => rendered.push(html),
      visit: () => {
        throw new Error("visit should not run for inline turbo-stream updates")
      },
    }

    const ok = await postAndRenderTurboStream(
      "/conversations/123/regenerate",
      { agent_node_id: "node-1" },
      { documentLike, turbo, fetchImpl },
    )

    expect(ok).toBe(true)
    expect(rendered).toEqual(['<turbo-stream action="replace" target="conversation_123_messages_list"></turbo-stream>'])
  })
})
