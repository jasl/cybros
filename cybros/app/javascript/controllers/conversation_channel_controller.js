import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"
import { boundedPush, compareEventIds, sortEventsByEventId } from "../lib/event_id"

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
    this.pendingEventsByNodeId = new Map()
    this.pendingNodeStateByNodeId = new Map()
    this.pendingFlushTimerByNodeId = new Map()
    this.postAppendRefreshTimerByNodeId = new Map()
    this.mutationObserver = new MutationObserver((mutations) => this.#onMutations(mutations))
    this.mutationObserver.observe(this.element, { childList: true, subtree: true })

    this.element.setAttribute("data-conversation-channel-connected", "false")

    this.subscription = consumer.subscriptions.create(
      {
        channel: "ConversationChannel",
        conversation_id: this.conversationIdValue,
        cursor: this.cursor || undefined,
      },
      {
        connected: () => this.element.setAttribute("data-conversation-channel-connected", "true"),
        disconnected: () => this.element.setAttribute("data-conversation-channel-connected", "false"),
        received: (data) => this.#received(data),
      },
    )

    this.stuckTimer = window.setInterval(() => this.#checkStuck(), 1000)

    // Best-effort convergence for control visibility (Stop/Retry) even when realtime node_state is missed.
    this.#reconcileControlsFromDom()
  }

  disconnect() {
    if (this.subscription) consumer.subscriptions.remove(this.subscription)
    this.subscription = null
    this.element.setAttribute("data-conversation-channel-connected", "false")

    if (this.stuckTimer) window.clearInterval(this.stuckTimer)
    this.stuckTimer = null

    if (this.mutationObserver) this.mutationObserver.disconnect()
    this.mutationObserver = null

    for (const id of this.pendingFlushTimerByNodeId.values()) {
      window.clearTimeout(id)
    }
    for (const id of this.postAppendRefreshTimerByNodeId.values()) {
      window.clearTimeout(id)
    }
    this.pendingFlushTimerByNodeId.clear()
    this.postAppendRefreshTimerByNodeId.clear()
    this.pendingEventsByNodeId.clear()
    this.pendingNodeStateByNodeId.clear()
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
      if (this.cursor && eventId && compareEventIds(eventId, this.cursor) <= 0) return

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
      } else if (nodeId) {
        this.#bufferNodeEvent(nodeId, data)
      }

      if (eventId && (!this.cursor || compareEventIds(eventId, this.cursor) > 0)) {
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
      if (!bubble && nodeId) {
        // Turbo append/replace can race with ActionCable delivery. Buffer the latest node_state and
        // apply once the bubble exists in the DOM.
        this.pendingNodeStateByNodeId.set(nodeId, to)
        return
      }

      this.#applyNodeState(bubble, nodeId, to)
      return
    }
  }

  #bufferNodeEvent(nodeId, event) {
    // Turbo append/replace can race with ActionCable delivery. Buffer briefly so we can
    // apply once the bubble exists in the DOM.
    const arr = this.pendingEventsByNodeId.get(nodeId) || []
    boundedPush(arr, event, 300)

    this.pendingEventsByNodeId.set(nodeId, arr)

    if (!this.pendingFlushTimerByNodeId.has(nodeId)) {
      const timerId =
        window.setTimeout(() => {
          this.pendingFlushTimerByNodeId.delete(nodeId)
          this.#flushPendingFor(nodeId)
        }, 50)
      this.pendingFlushTimerByNodeId.set(nodeId, timerId)
    }
  }

  #flushPendingFor(nodeId) {
    const bubble = this.#findAgentBubble(nodeId)
    if (!bubble) return

    const events = this.pendingEventsByNodeId.get(nodeId) || []
    if (events.length === 0) return

    this.pendingEventsByNodeId.delete(nodeId)

    // Ensure deterministic order in case buffered out-of-order.
    const ordered = sortEventsByEventId(events)

    for (const ev of ordered) {
      this.#applyNodeEvent(bubble, ev)
      if (String(ev.kind || "") === "output_delta") {
        this.activeNodeId = nodeId
        this.#showSpinner(bubble)
        this.#showStop()
      }
    }

    this.#maybeScrollToBottom()
  }

  #onMutations(mutations) {
    // When a new agent bubble appears, flush any buffered events.
    for (const m of mutations) {
      const added = Array.from(m.addedNodes || [])
      for (const node of added) {
        if (!(node instanceof Element)) continue
        const bubbles =
          node.matches?.('[data-role="agent-bubble"][data-node-id]')
            ? [node]
            : Array.from(node.querySelectorAll?.('[data-role="agent-bubble"][data-node-id]') || [])
        for (const bubble of bubbles) {
          const nodeId = bubble.getAttribute("data-node-id") || ""
          if (nodeId) {
            this.#flushPendingFor(nodeId)
            this.#flushPendingNodeStateFor(nodeId)
            this.#schedulePostAppendRefresh(nodeId)
            this.#reconcileControlsFromDom()
          }
        }
      }
    }
  }

  #schedulePostAppendRefresh(nodeId) {
    if (!nodeId) return
    if (this.postAppendRefreshTimerByNodeId.has(nodeId)) return

    // If both realtime deliveries are missed (page load races), converge from durable HTTP truth.
    const timerId =
      window.setTimeout(() => {
        this.postAppendRefreshTimerByNodeId.delete(nodeId)
        this.#refreshMessage(nodeId)
      }, 750)
    this.postAppendRefreshTimerByNodeId.set(nodeId, timerId)
  }

  #refreshMessage(nodeId) {
    const bubble = this.#findAgentBubble(nodeId)
    if (!bubble) return
    if (!window.Turbo?.renderStreamMessage) return

    const state = String(bubble.getAttribute("data-node-state") || "")
    if (["finished", "errored", "stopped", "rejected", "skipped"].includes(state)) {
      this.#reconcileControlsFromDom()
      return
    }

    const url = `/conversations/${encodeURIComponent(this.conversationIdValue)}/messages/refresh?node_id=${encodeURIComponent(nodeId)}`
    fetch(url, {
      method: "GET",
      headers: { Accept: "text/vnd.turbo-stream.html" },
      credentials: "same-origin",
    })
      .then((res) => (res.ok ? res.text() : ""))
      .then((html) => {
        if (!html) return
        window.Turbo.renderStreamMessage(html)
        this.#reconcileControlsFromDom()
      })
      .catch(() => {})
  }

  #reconcileControlsFromDom() {
    const bubbles = Array.from(this.element.querySelectorAll('[data-role="agent-bubble"][data-node-id]'))
    const last = bubbles[bubbles.length - 1]
    if (!last) return

    const state = String(last.getAttribute("data-node-state") || "")
    const nodeId = String(last.getAttribute("data-node-id") || "")

    if (state === "running" || state === "pending") {
      this.activeNodeId = nodeId || this.activeNodeId
      this.#showStop()
      this.#hideRetry()
      return
    }

    this.#hideStop()

    if (state === "errored") {
      this.lastErroredNodeId = nodeId || this.lastErroredNodeId
      this.#showRetry()
    } else {
      this.#hideRetry()
    }
  }

  #flushPendingNodeStateFor(nodeId) {
    const bubble = this.#findAgentBubble(nodeId)
    if (!bubble) return

    const to = this.pendingNodeStateByNodeId.get(nodeId)
    if (!to) return

    this.pendingNodeStateByNodeId.delete(nodeId)
    this.#applyNodeState(bubble, nodeId, to)
  }

  #applyNodeState(bubble, nodeId, to) {
    if (to === "running") {
      this.activeNodeId = nodeId
      this.lastErroredNodeId = null
      this.lastEventAt = Date.now()
      if (bubble) bubble.setAttribute("data-node-state", "running")
      this.#showSpinner(bubble)
      this.#showStop()
      this.#hideRetry()
      this.#hideStuck()
      this.#emitDebug()
      return
    }

    if (["finished", "errored", "stopped", "rejected", "skipped"].includes(to)) {
      if (this.activeNodeId === nodeId) this.activeNodeId = null
      if (bubble) bubble.setAttribute("data-node-state", to)
      this.#hideSpinner(bubble)
      this.#hideStop()
      if (to === "errored") {
        this.lastErroredNodeId = nodeId
        this.#showRetry()
      }
      if (to === "errored") this.#showError(bubble, "Generation failed")
      this.#maybeRefreshTerminalMessage(nodeId, bubble)
      this.#reconcileControlsFromDom()
      this.#emitDebug()
    }
  }

  #maybeRefreshTerminalMessage(nodeId, bubble) {
    // If the Turbo::StreamsChannel `replace` is missed (cable reconnect, early broadcast),
    // converge via an explicit HTTP turbo-stream fetch for the terminal message.
    if (!nodeId || !bubble) return
    if (bubble.querySelector('[data-controller="markdown"]')) return

    window.setTimeout(() => {
      if (bubble.querySelector('[data-controller="markdown"]')) return
      if (!window.Turbo?.renderStreamMessage) return

      const url = `/conversations/${encodeURIComponent(this.conversationIdValue)}/messages/refresh?node_id=${encodeURIComponent(nodeId)}`
      fetch(url, {
        method: "GET",
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin",
      })
        .then((res) => (res.ok ? res.text() : ""))
        .then((html) => {
          if (html) window.Turbo.renderStreamMessage(html)
        })
        .catch(() => {})
    }, 250)
  }

  #applyNodeEvent(bubble, event) {
    const kind = String(event.kind || "")
    const progressEl = bubble.querySelector("[data-role='progress']")

    if (kind === "progress" || kind === "log") {
      if (!progressEl) return
      const text = String(event.text || "").trim()
      progressEl.textContent = text
      if (text) progressEl.classList.remove("hidden")
      else progressEl.classList.add("hidden")
      return
    }

    const textEl = bubble.querySelector("[data-role='text']")
    if (!textEl) return

    if (kind === "output_delta") {
      progressEl?.classList.add("hidden")
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
