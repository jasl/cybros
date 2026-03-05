export function createTurboStreamBuffer({
  getElementById,
  renderStreamMessage,
  now = () => Date.now(),
  maxEntries = 100,
  maxAgeMs = 30_000,
} = {}) {
  const bufferByTarget = new Map()

  function evictStaleEntries() {
    const cutoff = now() - maxAgeMs
    for (const [target, entry] of bufferByTarget.entries()) {
      if (!entry || entry.insertedAt < cutoff) bufferByTarget.delete(target)
    }
    while (bufferByTarget.size > maxEntries) {
      const firstKey = bufferByTarget.keys().next().value
      if (!firstKey) break
      bufferByTarget.delete(firstKey)
    }
  }

  function onBeforeStreamRender(event) {
    const stream = event?.target
    if (!stream) return

    const action = String(stream.getAttribute?.("action") || "")
    const target = String(stream.getAttribute?.("target") || "")

    // Only buffer message replacements (chat bubbles). Anything else should behave normally.
    if (action !== "replace" && action !== "update") return
    if (!target.startsWith("message_")) return

    const exists = typeof getElementById === "function" ? Boolean(getElementById(target)) : false
    if (exists) return

    const html = String(stream.outerHTML || "")
    if (!html) return

    bufferByTarget.set(target, { html, insertedAt: now() })
    evictStaleEntries()

    // Stop Turbo from rendering a stream targeting a missing element (it would be dropped).
    if (typeof event.preventDefault === "function") event.preventDefault()
    if (event.detail && typeof event.detail === "object") {
      event.detail.render = () => {}
    }
  }

  function flush() {
    if (typeof getElementById !== "function") return
    if (typeof renderStreamMessage !== "function") return

    evictStaleEntries()

    for (const [target, entry] of bufferByTarget.entries()) {
      if (!getElementById(target)) continue
      renderStreamMessage(entry.html)
      bufferByTarget.delete(target)
    }
  }

  return { onBeforeStreamRender, flush }
}

export function installTurboStreamBuffer({
  scopeRoot = document.documentElement,
  turbo = window.Turbo,
} = {}) {
  if (!turbo || typeof turbo.renderStreamMessage !== "function") return null

  const buffer = createTurboStreamBuffer({
    getElementById: (id) => document.getElementById(id),
    renderStreamMessage: (html) => turbo.renderStreamMessage(html),
  })

  const onBeforeStreamRender = (event) => buffer.onBeforeStreamRender(event)
  document.addEventListener("turbo:before-stream-render", onBeforeStreamRender)

  const observer = new MutationObserver(() => buffer.flush())
  if (scopeRoot) observer.observe(scopeRoot, { childList: true, subtree: true })

  return {
    uninstall() {
      document.removeEventListener("turbo:before-stream-render", onBeforeStreamRender)
      observer.disconnect()
    },
  }
}
