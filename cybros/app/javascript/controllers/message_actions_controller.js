import { Controller } from "@hotwired/stimulus"
import { postAndTurboVisit } from "../lib/post_and_turbo_visit"

const registryByList = new WeakMap()

function listEntryFor(listEl) {
  if (!listEl) return null
  let entry = registryByList.get(listEl)
  if (entry) return entry

  entry = {
    controllers: new Set(),
    observer: null,
  }

  entry.observer = new MutationObserver(() => {
    for (const controller of entry.controllers) controller.updateVisibility()
  })
  entry.observer.observe(listEl, { childList: true })

  registryByList.set(listEl, entry)
  return entry
}

function registerController(controller) {
  const listEl = controller.messagesListElement()
  const entry = listEntryFor(listEl)
  if (!entry) return
  entry.controllers.add(controller)
}

function unregisterController(controller) {
  const listEl = controller.messagesListElement()
  const entry = listEl ? registryByList.get(listEl) : null
  if (!entry) return

  entry.controllers.delete(controller)
  if (entry.controllers.size === 0) {
    entry.observer?.disconnect?.()
    registryByList.delete(listEl)
  }
}

function tailAgentNodeId(listEl) {
  if (!listEl) return null
  const bubbles = listEl.querySelectorAll?.('[data-role="agent-bubble"][data-node-id]') || []
  const last = bubbles.length ? bubbles[bubbles.length - 1] : null
  return last?.getAttribute?.("data-node-id") || null
}

function terminalState(state) {
  return ["finished", "errored", "stopped", "rejected", "skipped"].includes(String(state || ""))
}

export default class extends Controller {
  static values = {
    nodeId: String,
    role: String,
  }

  static targets = ["copyButton", "regenerateButton", "swipeNav", "swipeLeft", "swipeRight", "branchButton"]

  connect() {
    registerController(this)
    this.updateVisibility()
  }

  disconnect() {
    unregisterController(this)
  }

  messagesListElement() {
    return this.element.closest?.("[data-chat-scroll-target='list']") || null
  }

  conversationId() {
    const root = this.element.closest?.("[data-conversation-channel-conversation-id-value]")
    return root?.getAttribute?.("data-conversation-channel-conversation-id-value") || ""
  }

  updateVisibility() {
    const role = String(this.roleValue || "")
    const nodeId = String(this.nodeIdValue || "")

    const listEl = this.messagesListElement()
    const tailId = tailAgentNodeId(listEl)
    const isTailAgent = role === "agent" && nodeId && tailId && nodeId === tailId

    const bubbleState = this.element.querySelector("[data-role='agent-bubble']")?.getAttribute?.("data-node-state") || ""
    const isTerminal = terminalState(bubbleState)
    const canRegenerate = role === "agent" && bubbleState === "finished"
    const canSwipe = role === "agent" && isTailAgent && bubbleState === "finished"
    const canBranch = role === "user" ? true : (role === "agent" && isTerminal)

    if (this.hasSwipeNavTarget) {
      this.swipeNavTarget.classList.toggle("hidden", !canSwipe)
    }

    if (this.hasRegenerateButtonTarget) {
      this.regenerateButtonTarget.title = isTailAgent ? "Regenerate" : "Regenerate (creates branch)"
      this.regenerateButtonTarget.toggleAttribute("disabled", !canRegenerate)
      this.regenerateButtonTarget.classList.toggle("btn-disabled", !canRegenerate)
    }

    if (this.hasBranchButtonTarget) {
      this.branchButtonTarget.toggleAttribute("disabled", !canBranch)
      this.branchButtonTarget.classList.toggle("btn-disabled", !canBranch)
    }
  }

  async copy(event) {
    event.preventDefault()

    const text = this.#extractCopyText()
    if (!text) return

    try {
      await navigator.clipboard?.writeText?.(text)
    } catch (_e) {
      // best-effort; no toast here (avoid coupling)
    }
  }

  async regenerate(event) {
    event.preventDefault()
    const conversationId = this.conversationId()
    const nodeId = String(this.nodeIdValue || "")
    if (!conversationId || !nodeId) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/regenerate`
    await postAndTurboVisit(url, { agent_node_id: nodeId })
  }

  async swipeLeft(event) {
    event.preventDefault()
    await this.#swipe("left")
  }

  async swipeRight(event) {
    event.preventDefault()
    await this.#swipe("right")
  }

  async branch(event) {
    event.preventDefault()
    const conversationId = this.conversationId()
    const nodeId = String(this.nodeIdValue || "")
    if (!conversationId || !nodeId) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/branch`
    await postAndTurboVisit(url, { from_node_id: nodeId, title: "Branch", user_content: "" })
  }

  async #swipe(direction) {
    const conversationId = this.conversationId()
    const nodeId = String(this.nodeIdValue || "")
    if (!conversationId || !nodeId) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/swipe`
    await postAndTurboVisit(url, { agent_node_id: nodeId, direction })
  }

  #extractCopyText() {
    // Prefer raw markdown for agent messages when present.
    const markdownTemplate = this.element.querySelector("template[data-markdown-target='content']")
    if (markdownTemplate) {
      const raw = String(markdownTemplate.content?.textContent || "")
      if (raw.trim().length) return raw
    }

    // Fallback to visible text.
    const bubbleText = this.element.querySelector("[data-role='text']")?.textContent
    if (bubbleText && bubbleText.trim().length) return bubbleText

    const userText = this.element.querySelector("[data-role='user-text']")?.textContent
    if (userText && userText.trim().length) return userText

    return ""
  }
}
