import { Controller } from "@hotwired/stimulus"
import { postAndTurboVisit } from "../lib/post_and_turbo_visit"

function actionEntry(policy, key) {
  const actions = policy?.actions
  if (!actions || typeof actions !== "object") return {}
  const entry = actions[key]
  return entry && typeof entry === "object" ? entry : {}
}

function actionAvailable(policy, key) {
  return actionEntry(policy, key).available === true
}

function interruptedOutputPolicyOverrideValue() {
  const input = document.querySelector('input[name="interrupted_output_policy_override"]')
  const value = String(input?.value || "").trim()
  return value || null
}

export default class extends Controller {
  static values = {
    nodeId: String,
    role: String,
    actionPolicy: Object,
  }

  static targets = ["copyButton", "retryButton", "regenerateButton", "swipeNav", "swipeLeft", "swipeRight", "branchButton"]

  connect() {
    this.updateVisibility()
  }

  conversationId() {
    const root = this.element.closest?.("[data-conversation-channel-conversation-id-value]")
    return root?.getAttribute?.("data-conversation-channel-conversation-id-value") || ""
  }

  updateVisibility() {
    const policy = this.actionPolicyValue || {}
    const regenerate = actionEntry(policy, "regenerate")

    if (this.hasSwipeNavTarget) {
      this.swipeNavTarget.classList.toggle("hidden", !actionAvailable(policy, "swipe"))
    }

    if (this.hasRegenerateButtonTarget) {
      const branchMode = regenerate.mode === "branch"
      this.regenerateButtonTarget.title = branchMode ? "Regenerate (creates branch)" : "Regenerate"
      this.regenerateButtonTarget.toggleAttribute("disabled", !actionAvailable(policy, "regenerate"))
      this.regenerateButtonTarget.classList.toggle("btn-disabled", !actionAvailable(policy, "regenerate"))
    }

    if (this.hasRetryButtonTarget) {
      this.retryButtonTarget.toggleAttribute("disabled", !actionAvailable(policy, "retry"))
      this.retryButtonTarget.classList.toggle("btn-disabled", !actionAvailable(policy, "retry"))
    }

    if (this.hasBranchButtonTarget) {
      const canBranch = actionAvailable(policy, "branch")
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

  async retry(event) {
    event.preventDefault()
    const conversationId = this.conversationId()
    const nodeId = String(this.nodeIdValue || "")
    if (!conversationId || !nodeId) return
    if (!actionAvailable(this.actionPolicyValue || {}, "retry")) return

    const interruptedOutputPolicyOverride = interruptedOutputPolicyOverrideValue()
    const body = { node_id: nodeId }
    if (interruptedOutputPolicyOverride) {
      body.interrupted_output_policy_override = interruptedOutputPolicyOverride
    }

    const response = await this.#postJson(`/conversations/${encodeURIComponent(conversationId)}/retry`, body)
    if (!response?.ok) {
      await this.#toastRetryFailure(response)
      return
    }

    window.Turbo?.visit?.(window.location.href)
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
    if (!actionAvailable(this.actionPolicyValue || {}, "swipe")) return

    const url = `/conversations/${encodeURIComponent(conversationId)}/swipe`
    await postAndTurboVisit(url, { agent_node_id: nodeId, direction })
  }

  async #postJson(url, body) {
    const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
    if (!token) return null

    return fetch(url, {
      method: "POST",
      headers: {
        "X-CSRF-Token": token,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(body),
      credentials: "same-origin",
    })
  }

  async #toastRetryFailure(response) {
    let message = "Retry failed."

    try {
      const payload = await response.json()
      const code = String(payload?.error || "")
      if (code === "retry_already_queued") message = "Retry is already queued."
      else if (code === "not_retryable") message = "This message cannot be retried."
    } catch (_e) {
      // best-effort
    }

    window.dispatchEvent(
      new CustomEvent("toast:show", {
        detail: { message, type: "error" },
        bubbles: true,
        cancelable: true,
      }),
    )
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
