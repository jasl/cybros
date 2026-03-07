import { Controller } from "@hotwired/stimulus"
import { postAndTurboVisit } from "../lib/post_and_turbo_visit"

function isActiveElementInAnyInput() {
  const el = document.activeElement
  if (!el) return false
  if (el.tagName === "INPUT") return true
  if (el.tagName === "TEXTAREA") return true
  return !!el.isContentEditable
}

function tailAgentBubble(listEl) {
  if (!listEl) return ""
  const bubbles = listEl.querySelectorAll?.('[data-role="agent-bubble"][data-node-id]') || []
  return bubbles.length ? bubbles[bubbles.length - 1] : null
}

function tailAgentNodeId(listEl) {
  const bubble = tailAgentBubble(listEl)
  return String(bubble?.getAttribute?.("data-node-id") || "")
}

function parseActionPolicy(bubble) {
  if (!bubble) return {}

  try {
    const raw = String(bubble.getAttribute("data-action-policy") || "")
    if (!raw) return {}

    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === "object" ? parsed : {}
  } catch (_e) {
    return {}
  }
}

function actionAvailable(policy, key) {
  const actions = policy?.actions
  const entry = actions && typeof actions === "object" ? actions[key] : null
  return entry?.available === true
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

    // Ctrl+Enter: replay the tail assistant using its projected action policy.
    if (event.key === "Enter" && event.ctrlKey && !event.shiftKey && !event.altKey && !event.metaKey) {
      const policy = this.#tailAgentActionPolicy()
      if (!actionAvailable(policy, "retry") && !actionAvailable(policy, "regenerate")) return
      event.preventDefault()
      this.#replayTail(policy)
      return
    }

    // ArrowLeft/ArrowRight: swipe tail assistant (only when textarea is empty)
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      if (isActiveElementInAnyInput()) return
      if (this.hasTextareaTarget && this.textareaTarget.value.trim().length > 0) return
      if (event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return

      const nodeId = this.#tailAgentNodeId()
      if (!nodeId) return
      if (!actionAvailable(this.#tailAgentActionPolicy(), "swipe")) return

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

  #tailAgentActionPolicy() {
    return parseActionPolicy(tailAgentBubble(this.#messagesListElement()))
  }

  async #replayTail(policy) {
    if (actionAvailable(policy, "retry")) {
      await this.#retryTail()
      return
    }

    if (actionAvailable(policy, "regenerate")) {
      await this.#regenerateTail()
    }
  }

  async #regenerateTail() {
    const conversationId = this.#conversationId()
    const nodeId = this.#tailAgentNodeId()
    if (!conversationId || !nodeId) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/regenerate`
    await postAndTurboVisit(url, { agent_node_id: nodeId })
  }

  async #retryTail() {
    const retryButton = this.element.querySelector("[data-conversation-channel-target='retryButton']")
    if (!retryButton || retryButton.classList.contains("hidden")) return

    retryButton.click()
  }

  async #swipeTail(direction) {
    const conversationId = this.#conversationId()
    const nodeId = this.#tailAgentNodeId()
    if (!conversationId || !nodeId) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/swipe`
    await postAndTurboVisit(url, { agent_node_id: nodeId, direction })
  }
}
