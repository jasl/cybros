import { Controller } from "@hotwired/stimulus"

function isActiveElementInAnyInput({ textareaTarget } = {}) {
  const el = document.activeElement
  if (!el) return false
  if (el.tagName === "INPUT") return true
  if (el.tagName === "TEXTAREA") return el !== textareaTarget
  return !!el.isContentEditable
}

function tailAgentNodeId(listEl) {
  if (!listEl) return ""
  const bubbles = listEl.querySelectorAll?.('[data-role="agent-bubble"][data-node-id]') || []
  const last = bubbles.length ? bubbles[bubbles.length - 1] : null
  return String(last?.getAttribute?.("data-node-id") || "")
}

export default class extends Controller {
  static targets = ["textarea"]

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
  }

  handleKeydown(event) {
    // IME protection (CJK input)
    if (event.isComposing) return

    // ?: open help (when not in any input)
    if (event.key === "?") {
      if (isActiveElementInAnyInput({ textareaTarget: this.hasTextareaTarget ? this.textareaTarget : null })) return
      event.preventDefault()
      document.getElementById("hotkeys_help_modal")?.showModal?.()
      return
    }

    // Escape: stop generation (best-effort)
    if (event.key === "Escape") {
      const stopButton = this.element.querySelector("[data-conversation-channel-target='stopButton']")
      if (stopButton && !stopButton.classList.contains("hidden")) {
        event.preventDefault()
        stopButton.click()
      }
      return
    }

    // Ctrl+Enter: regenerate tail assistant
    if (event.key === "Enter" && event.ctrlKey && !event.shiftKey && !event.altKey && !event.metaKey) {
      if (!this.#tailAgentNodeId()) return
      event.preventDefault()
      this.#regenerateTail()
      return
    }

    // ArrowLeft/ArrowRight: swipe tail assistant (only when textarea is empty)
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      if (isActiveElementInAnyInput({ textareaTarget: this.hasTextareaTarget ? this.textareaTarget : null })) return
      if (this.hasTextareaTarget && this.textareaTarget.value.trim().length > 0) return
      if (event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return

      const nodeId = this.#tailAgentNodeId()
      if (!nodeId) return

      event.preventDefault()
      const direction = event.key === "ArrowLeft" ? "left" : "right"
      this.#swipeTail(direction)
    }
  }

  #conversationId() {
    return String(this.element.getAttribute("data-conversation-channel-conversation-id-value") || "")
  }

  #messagesListElement() {
    return this.element.querySelector?.("[data-chat-scroll-target='list']") || null
  }

  #tailAgentNodeId() {
    return tailAgentNodeId(this.#messagesListElement())
  }

  async #regenerateTail() {
    const conversationId = this.#conversationId()
    const nodeId = this.#tailAgentNodeId()
    if (!conversationId || !nodeId) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/regenerate`
    await this.#postAndVisit(url, { agent_node_id: nodeId })
  }

  async #swipeTail(direction) {
    const conversationId = this.#conversationId()
    const nodeId = this.#tailAgentNodeId()
    if (!conversationId || !nodeId) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/swipe`
    await this.#postAndVisit(url, { agent_node_id: nodeId, direction })
  }

  async #postAndVisit(url, params) {
    const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
    if (!token) return

    const body = new URLSearchParams()
    for (const [k, v] of Object.entries(params || {})) body.set(k, String(v ?? ""))

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
    if (nextUrl && window.Turbo?.visit) {
      window.Turbo.visit(nextUrl)
    } else if (nextUrl) {
      window.location.href = nextUrl
    }
  }
}

