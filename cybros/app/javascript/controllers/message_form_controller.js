import { Controller } from "@hotwired/stimulus"
import {
  deriveComposerFormState,
  normalizeComposerRailState,
  prependQueuedContentToDraft,
} from "../lib/conversation_composer_state"

export default class extends Controller {
  static targets = [
    "textarea",
    "statusRail",
    "editMode",
    "editModeLabel",
    "editNodeIdInput",
    "runningInputPolicyInput",
    "queueAlertExpanded",
    "queueToggleButton",
    "queueToggleIcon",
  ]

  connect() {
    this.defaultAction = this.element.action
    this.queueExpanded = false
    this.handleMessageEdit = this.handleMessageEdit.bind(this)
    window.addEventListener("conversation:user-message-edit", this.handleMessageEdit)
    this.autoResize()
    this.#syncComposerState()
  }

  disconnect() {
    window.removeEventListener("conversation:user-message-edit", this.handleMessageEdit)
  }

  statusRailTargetConnected() {
    this.#syncComposerState()
  }

  submit(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return
    const textarea = this.hasTextareaTarget ? this.textareaTarget : form.querySelector("textarea")
    if (!textarea) return

    const value = textarea.value.trim()
    if (!value) {
      event.preventDefault()
      textarea.focus()
      return
    }

    this.#syncComposerState()
  }

  keydown(event) {
    if (event.key !== "Enter") return
    if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return

    event.preventDefault()
    this.element.requestSubmit?.()
  }

  submitEnd(event) {
    if (event.detail?.success !== true) return
    if (!this.hasTextareaTarget) return

    this.#clearEditState()
    this.textareaTarget.value = ""
    this.autoResize()
    this.#syncComposerState()
  }

  autoResize() {
    if (!this.hasTextareaTarget) return
    const el = this.textareaTarget
    el.style.height = "auto"
    el.style.height = `${el.scrollHeight}px`
  }

  toggleQueueDetails(event) {
    event.preventDefault()
    this.queueExpanded = !this.queueExpanded
    this.#renderQueueAlert()
  }

  handleMessageEdit(event) {
    const detail = event?.detail
    if (!detail || String(detail.conversationId || "") !== this.#conversationId()) return

    const nodeId = String(detail.nodeId || "").trim()
    const content = String(detail.content || "")
    if (!nodeId || !content.trim()) return

    if (this.hasTextareaTarget) {
      this.textareaTarget.value = content
      this.autoResize()
      this.textareaTarget.focus()
      this.textareaTarget.setSelectionRange?.(content.length, content.length)
    }

    if (this.hasEditNodeIdInputTarget) {
      this.editNodeIdInputTarget.value = nodeId
      this.editNodeIdInputTarget.disabled = false
    }

    if (this.hasEditModeTarget) {
      this.editModeTarget.classList.remove("hidden")
      this.editModeTarget.classList.add("flex")
    }

    if (this.hasEditModeLabelTarget) {
      this.editModeLabelTarget.textContent = "Editing your last message. Sending will regenerate the latest assistant reply."
    }
  }

  cancelEdit(event) {
    event.preventDefault()
    this.#clearEditState()
    this.hasTextareaTarget && this.textareaTarget.focus()
  }

  async editQueuedItem(event) {
    event.preventDefault()

    const button = event.currentTarget
    const url = String(button?.dataset?.actionUrl || "")
    const queuedContent = String(button?.dataset?.queuedContent || "")
    if (!url) return

    const payload = await this.#submitQueueAction(url, { method: "POST" })
    if (!payload) return

    if (this.hasTextareaTarget) {
      this.textareaTarget.value = prependQueuedContentToDraft({
        queuedContent,
        draft: this.textareaTarget.value,
      })
      this.autoResize()
      this.textareaTarget.focus()
    }
  }

  async steerQueuedItem(event) {
    event.preventDefault()

    const button = event.currentTarget
    const url = String(button?.dataset?.actionUrl || "")
    if (!url) return

    await this.#submitQueueAction(url, {
      method: "POST",
      body: {
        model_ref: this.#currentModelRef(),
        interrupted_output_policy_override: this.#interruptedOutputPolicyOverride(),
      },
    })
  }

  async cancelQueuedItem(event) {
    event.preventDefault()

    const button = event.currentTarget
    const url = String(button?.dataset?.actionUrl || "")
    if (!url) return

    await this.#submitQueueAction(url, { method: "DELETE" })
  }

  #syncComposerState() {
    const railState = this.#railState()
    const formState = deriveComposerFormState({ railState })

    this.element.action = formState.formAction || this.defaultAction

    if (this.hasRunningInputPolicyInputTarget) {
      const value = formState.runningInputPolicyOverride
      this.runningInputPolicyInputTarget.value = value || ""
      this.runningInputPolicyInputTarget.disabled = !value
    }

    if (railState.queuedCount <= 1) {
      this.queueExpanded = false
    }

    this.#renderQueueAlert()
  }

  #railState() {
    if (!this.hasStatusRailTarget) {
      return normalizeComposerRailState({ createUrl: this.defaultAction })
    }

    return normalizeComposerRailState(this.statusRailTarget.dataset)
  }

  #renderQueueAlert() {
    if (this.hasQueueAlertExpandedTarget) {
      this.queueAlertExpandedTarget.classList.toggle("hidden", !this.queueExpanded)
    }

    if (this.hasQueueToggleIconTarget) {
      this.queueToggleIconTarget.classList.toggle("rotate-180", this.queueExpanded)
    }

    if (this.hasQueueToggleButtonTarget) {
      const label = this.queueExpanded ? "Collapse queued messages" : "Expand queued messages"
      this.queueToggleButtonTarget.setAttribute("aria-label", label)
      this.queueToggleButtonTarget.title = this.queueExpanded ? "Collapse" : "Expand"
    }
  }

  async #submitQueueAction(url, { method, body = {} }) {
    const response = await this.#fetchJson(url, { method, body })
    if (!response?.ok) {
      this.#showToast("Queue action failed.")
      return null
    }

    const payload = await response.json().catch(() => null)
    if (payload?.turbo_stream && window.Turbo?.renderStreamMessage) {
      window.Turbo.renderStreamMessage(payload.turbo_stream)
    }

    return payload
  }

  async #fetchJson(url, { method, body }) {
    const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
    if (!token) return null

    return fetch(url, {
      method,
      headers: {
        "X-CSRF-Token": token,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(body),
      credentials: "same-origin",
    })
  }

  #currentModelRef() {
    const modelSelect = this.element.querySelector('select[name="model_ref"]')
    return String(modelSelect?.value || "").trim()
  }

  #interruptedOutputPolicyOverride() {
    const input = this.element.querySelector('input[name="interrupted_output_policy_override"]')
    return String(input?.value || "").trim()
  }

  #showToast(message) {
    window.dispatchEvent(
      new CustomEvent("toast:show", {
        detail: { message, type: "error" },
        bubbles: true,
        cancelable: true,
      }),
    )
  }

  #clearEditState() {
    if (this.hasEditNodeIdInputTarget) {
      this.editNodeIdInputTarget.value = ""
      this.editNodeIdInputTarget.disabled = true
    }

    if (this.hasEditModeTarget) {
      this.editModeTarget.classList.add("hidden")
      this.editModeTarget.classList.remove("flex")
    }
  }

  #conversationId() {
    const root = this.element.closest?.("[data-conversation-channel-conversation-id-value]")
    return String(root?.getAttribute?.("data-conversation-channel-conversation-id-value") || "")
  }
}
