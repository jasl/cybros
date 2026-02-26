import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["scroll", "list", "sentinel"]

  connect() {
    this.loading = false
    this.suppressAutoScroll = false

    this.mutationObserver = new MutationObserver((mutations) => this.#onMutations(mutations))
    if (this.hasListTarget) {
      this.mutationObserver.observe(this.listTarget, { childList: true })
    }

    this.#ensureObserver()
  }

  disconnect() {
    this.#teardownObserver()
    if (this.mutationObserver) this.mutationObserver.disconnect()
    this.mutationObserver = null
  }

  sentinelTargetConnected() {
    this.#ensureObserver()
  }

  sentinelTargetDisconnected() {
    this.#teardownObserver()
  }

  loadOlder() {
    this.#maybeLoadOlder({ force: true })
  }

  #ensureObserver() {
    if (this.observer) return
    if (!this.hasSentinelTarget) return

    this.observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue
          this.#maybeLoadOlder({ force: false })
        }
      },
      {
        root: this.hasScrollTarget ? this.scrollTarget : null,
        rootMargin: "0px",
        threshold: 0,
      },
    )

    this.observer.observe(this.sentinelTarget)
  }

  #teardownObserver() {
    if (!this.observer) return
    try {
      if (this.hasSentinelTarget) this.observer.unobserve(this.sentinelTarget)
    } catch (_) {}
    this.observer.disconnect()
    this.observer = null
  }

  async #maybeLoadOlder({ force }) {
    if (!this.hasScrollTarget) return
    if (!this.hasSentinelTarget) return

    if (this.loading) return
    if (!force && !this.#hasMore()) return

    const beforeCursor = this.#beforeCursor()
    if (!beforeCursor) return

    const url = this.#buildUrl({ before: beforeCursor })
    if (!url) return

    this.loading = true
    this.suppressAutoScroll = true

    const scrollEl = this.scrollTarget
    const scrollHeightBefore = scrollEl.scrollHeight
    const scrollTopBefore = scrollEl.scrollTop

    try {
      const res = await fetch(url.toString(), {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin",
      })

      if (res.status === 204) {
        this.sentinelTarget.dataset.chatScrollHasMoreValue = "false"
        this.sentinelTarget.dataset.chatScrollBeforeCursorValue = ""
        return
      }
      if (!res.ok) return

      const html = await res.text()
      if (!html) return

      if (window.Turbo?.renderStreamMessage) {
        window.Turbo.renderStreamMessage(html)
      }
    } finally {
      requestAnimationFrame(() => {
        const scrollHeightAfter = scrollEl.scrollHeight
        const delta = scrollHeightAfter - scrollHeightBefore
        scrollEl.scrollTop = scrollTopBefore + delta
        this.suppressAutoScroll = false
        this.loading = false
      })
    }
  }

  #onMutations(mutations) {
    if (this.suppressAutoScroll) return
    if (!this.hasScrollTarget) return
    if (!mutations.some((m) => m.addedNodes && m.addedNodes.length > 0)) return

    if (this.#nearBottom()) {
      this.scrollTarget.scrollTop = this.scrollTarget.scrollHeight
    }
  }

  #nearBottom() {
    const el = this.scrollTarget
    return el.scrollHeight - el.scrollTop - el.clientHeight < 120
  }

  #hasMore() {
    const raw = this.sentinelTarget?.dataset?.chatScrollHasMoreValue
    return raw === "true" || raw === "1"
  }

  #beforeCursor() {
    return this.sentinelTarget?.dataset?.chatScrollBeforeCursorValue || ""
  }

  #buildUrl({ before }) {
    const base = this.element?.dataset?.chatScrollLoadMoreUrlValue
    if (!base) return null

    const url = new URL(base, window.location.origin)
    if (before) url.searchParams.set("before", before)
    return url
  }
}

