import { Controller } from "@hotwired/stimulus"

function tailAgentNodeId(listEl) {
  if (!listEl) return ""
  const bubbles = listEl.querySelectorAll?.('[data-role="agent-bubble"][data-node-id]') || []
  const last = bubbles.length ? bubbles[bubbles.length - 1] : null
  return String(last?.getAttribute?.("data-node-id") || "")
}

export default class extends Controller {
  static values = {
    nodeId: String,
  }

  connect() {
    this.touchStartX = 0
    this.touchStartY = 0
    this.touchStartTime = 0

    this.onStart = (e) => this.#handleTouchStart(e)
    this.onMove = (e) => this.#handleTouchMove(e)
    this.onEnd = (e) => this.#handleTouchEnd(e)

    this.element.addEventListener("touchstart", this.onStart, { passive: true })
    this.element.addEventListener("touchmove", this.onMove, { passive: true })
    this.element.addEventListener("touchend", this.onEnd, { passive: true })
  }

  disconnect() {
    this.element.removeEventListener("touchstart", this.onStart)
    this.element.removeEventListener("touchmove", this.onMove)
    this.element.removeEventListener("touchend", this.onEnd)
  }

  #messagesListElement() {
    return this.element.closest?.("[data-chat-scroll-target='list']") || null
  }

  #conversationId() {
    const root = this.element.closest?.("[data-conversation-channel-conversation-id-value]")
    return String(root?.getAttribute?.("data-conversation-channel-conversation-id-value") || "")
  }

  #isTailAgent() {
    const nodeId = String(this.nodeIdValue || "")
    if (!nodeId) return false
    const tail = tailAgentNodeId(this.#messagesListElement())
    return !!tail && tail === nodeId
  }

  #handleTouchStart(event) {
    if (!this.#isTailAgent()) return
    const touch = event.touches?.[0]
    if (!touch) return
    this.touchStartX = touch.clientX
    this.touchStartY = touch.clientY
    this.touchStartTime = Date.now()
  }

  #handleTouchMove(_event) {
    // no-op; we only decide on end to avoid fighting scroll
  }

  #handleTouchEnd(event) {
    if (!this.#isTailAgent()) return
    const touch = event.changedTouches?.[0]
    if (!touch) return

    const dx = touch.clientX - this.touchStartX
    const dy = touch.clientY - this.touchStartY
    const dt = Date.now() - this.touchStartTime

    // Basic heuristic: horizontal swipe, reasonably fast.
    if (dt > 700) return
    if (Math.abs(dx) < 60) return
    if (Math.abs(dy) > 120) return
    if (Math.abs(dx) < Math.abs(dy)) return

    const direction = dx < 0 ? "right" : "left"
    this.#swipe(direction)
  }

  async #swipe(direction) {
    const conversationId = this.#conversationId()
    const nodeId = String(this.nodeIdValue || "")
    if (!conversationId || !nodeId) return

    const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
    if (!token) return

    const body = new URLSearchParams()
    body.set("agent_node_id", nodeId)
    body.set("direction", direction)

    const url = `/conversations/${encodeURIComponent(conversationId)}/swipe`

    let res
    try {
      res = await fetch(url, {
        method: "POST",
        headers: {
          "X-CSRF-Token": token,
          "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
          Accept: "text/html",
        },
        body,
        credentials: "same-origin",
        redirect: "follow",
      })
    } catch (_e) {
      return
    }

    const nextUrl = res?.url || ""
    if (nextUrl && window.Turbo?.visit) window.Turbo.visit(nextUrl)
    else if (nextUrl) window.location.href = nextUrl
  }
}

