import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static values = {
    conversationId: String,
  }

  static targets = ["scroll", "stopButton", "retryButton", "stuckAlert"]

  connect() {
    this.cursor = window.localStorage.getItem(this.#cursorKey()) || ""
    if (this.cursor && !this.#uuidLike(this.cursor)) {
      window.localStorage.removeItem(this.#cursorKey())
      this.cursor = ""
    }
    this.activeNodeId = null
    this.lastErroredNodeId = null
    this.lastEventAt = null

    this.subscription = consumer.subscriptions.create(
      {
        channel: "ConversationChannel",
        conversation_id: this.conversationIdValue,
        cursor: this.cursor || undefined,
      },
      {
        received: (data) => this.#received(data),
      },
    )

    this.stuckTimer = window.setInterval(() => this.#checkStuck(), 1000)
  }

  disconnect() {
    if (this.subscription) consumer.subscriptions.remove(this.subscription)
    this.subscription = null

    if (this.stuckTimer) window.clearInterval(this.stuckTimer)
    this.stuckTimer = null
  }

  stop() {
    if (!this.activeNodeId) return

    const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
    if (!token) return

    fetch(`/conversations/${this.conversationIdValue}/stop`, {
      method: "POST",
      headers: {
        "X-CSRF-Token": token,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({ node_id: this.activeNodeId }),
      credentials: "same-origin",
    }).catch(() => {})
  }

  retry() {
    const nodeId = this.activeNodeId || this.lastErroredNodeId
    if (!nodeId) return

    const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
    if (!token) return

    fetch(`/conversations/${this.conversationIdValue}/retry`, {
      method: "POST",
      headers: {
        "X-CSRF-Token": token,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({ node_id: nodeId }),
      credentials: "same-origin",
    })
      .then(() => window.Turbo?.visit?.(window.location.href))
      .catch(() => {})
  }

  #received(data) {
    if (!data || !data.type) return

    if (data.type === "replay_batch") {
      const events = Array.isArray(data.events) ? data.events : []
      for (const ev of events) this.#received(ev)
      return
    }

    if (data.type === "node_event") {
      const eventId = String(data.event_id || "")
      if (this.cursor && eventId && this.#compareEventIds(eventId, this.cursor) <= 0) return

      const nodeId = String(data.node_id || "")
      const bubble = this.#findAgentBubble(nodeId)
      if (bubble) {
        this.#applyNodeEvent(bubble, data)
        if (String(data.kind || "") === "output_delta") {
          this.activeNodeId = nodeId
          this.#showSpinner(bubble)
          this.#showStop()
        }
        this.#maybeScrollToBottom()
      }

      if (eventId && (!this.cursor || this.#compareEventIds(eventId, this.cursor) > 0)) {
        this.cursor = eventId
        window.localStorage.setItem(this.#cursorKey(), this.cursor)
      }

      this.lastEventAt = Date.now()
      this.#hideStuck()
      this.#hideRetry()
      this.#emitDebug()
      return
    }

    if (data.type === "node_state") {
      const nodeId = String(data.node_id || "")
      const to = String(data.to || "")

      const bubble = this.#findAgentBubble(nodeId)
      if (to === "running") {
        this.activeNodeId = nodeId
        this.lastErroredNodeId = null
        this.lastEventAt = Date.now()
        this.#showSpinner(bubble)
        this.#showStop()
        this.#hideRetry()
        this.#hideStuck()
        this.#emitDebug()
        return
      }

      if (["finished", "errored", "stopped", "rejected", "skipped"].includes(to)) {
        if (this.activeNodeId === nodeId) this.activeNodeId = null
        this.#hideSpinner(bubble)
        this.#hideStop()
        if (to === "errored") {
          this.lastErroredNodeId = nodeId
          this.#showRetry()
        }
        if (to === "errored") this.#showError(bubble, "Generation failed")
        this.#emitDebug()
        return
      }
    }
  }

  #applyNodeEvent(bubble, event) {
    const kind = String(event.kind || "")
    const textEl = bubble.querySelector("[data-role='text']")
    if (!textEl) return

    if (kind === "output_delta") {
      const delta = String(event.text || "")
      if (delta) textEl.appendChild(document.createTextNode(delta))
      return
    }

    if (kind === "output_compacted") {
      textEl.textContent = String(event.text || "")
    }
  }

  #findAgentBubble(nodeId) {
    if (!nodeId) return null
    const selector = `[data-role="agent-bubble"][data-node-id="${CSS.escape(nodeId)}"]`
    return this.element.querySelector(selector)
  }

  #showSpinner(bubble) {
    if (!bubble) return
    bubble.querySelector("[data-role='spinner']")?.classList.remove("hidden")
  }

  #hideSpinner(bubble) {
    if (!bubble) return
    bubble.querySelector("[data-role='spinner']")?.classList.add("hidden")
  }

  #showError(bubble, message) {
    if (!bubble) return
    const el = bubble.querySelector("[data-role='error']")
    if (!el) return
    el.textContent = message
    el.classList.remove("hidden")
  }

  #showStop() {
    if (!this.hasStopButtonTarget) return
    this.stopButtonTarget.classList.remove("hidden")
  }

  #hideStop() {
    if (!this.hasStopButtonTarget) return
    this.stopButtonTarget.classList.add("hidden")
  }

  #showRetry() {
    if (!this.hasRetryButtonTarget) return
    this.retryButtonTarget.classList.remove("hidden")
  }

  #hideRetry() {
    if (!this.hasRetryButtonTarget) return
    this.retryButtonTarget.classList.add("hidden")
  }

  #checkStuck() {
    if (!this.activeNodeId) return
    if (!this.lastEventAt) return

    const seconds = (Date.now() - this.lastEventAt) / 1000
    if (seconds < 30) return
    this.#showStuck()
    this.#showRetry()
  }

  #showStuck() {
    if (!this.hasStuckAlertTarget) return
    this.stuckAlertTarget.classList.remove("hidden")
  }

  #hideStuck() {
    if (!this.hasStuckAlertTarget) return
    this.stuckAlertTarget.classList.add("hidden")
  }

  #maybeScrollToBottom() {
    if (!this.hasScrollTarget) return
    const el = this.scrollTarget
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 120
    if (nearBottom) el.scrollTop = el.scrollHeight
  }

  #cursorKey() {
    return `cybros:conversation:${this.conversationIdValue}:cursor`
  }

  #compareEventIds(a, b) {
    const aStr = String(a || "")
    const bStr = String(b || "")
    if (!aStr && !bStr) return 0
    if (!aStr) return -1
    if (!bStr) return 1

    if (/^\d+$/.test(aStr) && /^\d+$/.test(bStr)) {
      const aInt = BigInt(aStr)
      const bInt = BigInt(bStr)
      if (aInt < bInt) return -1
      if (aInt > bInt) return 1
      return 0
    }

    return aStr.localeCompare(bStr)
  }

  #uuidLike(value) {
    const s = String(value || "")
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s)
  }

  #emitDebug() {
    this.dispatch("debug", {
      detail: {
        cursor: this.cursor,
        activeNodeId: this.activeNodeId,
        lastErroredNodeId: this.lastErroredNodeId,
        lastEventAt: this.lastEventAt,
      },
    })
  }
}

