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

export function mutationCouldRevealBufferedTarget(mutations) {
  const list = Array.isArray(mutations) ? mutations : []

  for (const m of list) {
    const added = Array.from(m?.addedNodes || [])
    for (const node of added) {
      const id = String(node?.id || "")
      if (id.startsWith("message_")) return true

      const descendants = node?.querySelectorAll?.("[id^='message_']")
      if (descendants && descendants.length > 0) return true
    }
  }

  return false
}

export function resolveTurboStreamBufferScopeRoot({
  documentLike = document,
  selector = "[data-turbo-stream-buffer-scope]",
} = {}) {
  const explicit = documentLike?.querySelector?.(selector)
  return explicit || documentLike?.body || documentLike?.documentElement || null
}

export function installTurboStreamBuffer({
  scopeRoot = null,
  turbo = window.Turbo,
  documentLike = document,
  MutationObserverClass = MutationObserver,
} = {}) {
  if (!turbo || typeof turbo.renderStreamMessage !== "function") return null

  const resolveRoot = () => {
    if (typeof scopeRoot === "function") {
      return scopeRoot({ documentLike }) || resolveTurboStreamBufferScopeRoot({ documentLike })
    }
    return scopeRoot || resolveTurboStreamBufferScopeRoot({ documentLike })
  }

  const buffer = createTurboStreamBuffer({
    getElementById: (id) => documentLike.getElementById(id),
    renderStreamMessage: (html) => turbo.renderStreamMessage(html),
  })

  const onBeforeStreamRender = (event) => buffer.onBeforeStreamRender(event)
  documentLike.addEventListener("turbo:before-stream-render", onBeforeStreamRender)

  const observer = new MutationObserverClass((mutations) => {
    if (mutationCouldRevealBufferedTarget(mutations)) buffer.flush()
  })

  let observedRoot = null
  const observeCurrentRoot = () => {
    const nextRoot = resolveRoot()
    if (!nextRoot) return
    if (nextRoot === observedRoot) return
    observer.disconnect()
    observer.observe(nextRoot, { childList: true, subtree: true })
    observedRoot = nextRoot
  }

  observeCurrentRoot()

  const onTurboLoad = () => observeCurrentRoot()
  documentLike.addEventListener("turbo:load", onTurboLoad)

  return {
    uninstall() {
      documentLike.removeEventListener("turbo:before-stream-render", onBeforeStreamRender)
      documentLike.removeEventListener("turbo:load", onTurboLoad)
      observer.disconnect()
    },
  }
}
