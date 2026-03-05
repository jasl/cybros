import { Controller } from "@hotwired/stimulus"
import { postAndTurboVisit } from "../lib/post_and_turbo_visit"

function isActiveElementInAnyInput() {
  const el = document.activeElement
  if (!el) return false
  if (el.tagName === "INPUT") return true
  if (el.tagName === "TEXTAREA") return true
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
      if (isActiveElementInAnyInput()) return
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
      if (isActiveElementInAnyInput()) return
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
    await postAndTurboVisit(url, { agent_node_id: nodeId })
  }

  async #swipeTail(direction) {
    const conversationId = this.#conversationId()
    const nodeId = this.#tailAgentNodeId()
    if (!conversationId || !nodeId) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/swipe`
    await postAndTurboVisit(url, { agent_node_id: nodeId, direction })
  }
}
