import { Controller } from "@hotwired/stimulus"
import {
  deriveComposerFormState,
  normalizeComposerRailState,
  prependQueuedContentToDraft,
} from "../lib/conversation_composer_state"

export default class extends Controller {
  static values = {
    composerDraftUrl: String,
  }

  static targets = [
    "textarea",
    "attachmentInput",
    "composerDraftUpdatedAtInput",
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
    this.submitInFlight = false
    this.draftSaveDelayMs = 250
    this.pendingDraftSaveTimer = null
    this.submittedDraft = null
    this.submittedComposerDraftUpdatedAt = null
    this.attachmentSelectionToken = 0
    this.submittedAttachmentSelectionToken = null
    this.pendingAttachmentRestoreFiles = null
    this.pendingSubmissions = []
    this.currentComposerDraftUpdatedAt = this.#currentComposerDraftUpdatedAt()
    this.handleMessageEdit = this.handleMessageEdit.bind(this)
    window.addEventListener("conversation:user-message-edit", this.handleMessageEdit)
    this.autoResize()
    this.#syncComposerState()
  }

  disconnect() {
    this.#clearDraftSaveTimer()
    window.removeEventListener("conversation:user-message-edit", this.handleMessageEdit)
    this.submittedAttachmentSelectionToken = null
    this.pendingAttachmentRestoreFiles = null
    this.pendingSubmissions = []
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
    const hasAttachments = this.#hasPendingAttachmentsForNewSubmission()
    if (!value && !hasAttachments) {
      event.preventDefault()
      textarea.focus()
      return
    }

    this.#clearDraftSaveTimer()
    this.#syncComposerState()

    if (this.submitInFlight && hasAttachments) {
      event.preventDefault()
      this.#showToast("Wait for the current send to finish before sending attachments.")
      return
    }

    if (this.submitInFlight) {
      event.preventDefault()

      const submission = this.#captureSubmission(form)
      if (!submission) return

      this.pendingSubmissions.push(submission)
      this.#clearComposerDraft({ clearAttachments: false })
      return
    }

    this.submittedDraft = value
    this.submittedComposerDraftUpdatedAt = this.#currentComposerDraftUpdatedAt()
    this.submittedAttachmentSelectionToken = this.#currentAttachmentSelectionToken()
    this.submitInFlight = true
  }

  attachmentInputChanged() {
    this.attachmentSelectionToken += 1
    this.pendingAttachmentRestoreFiles = null
  }

  draftChanged() {
    this.autoResize()
    this.#scheduleComposerDraftSave()
  }

  runtimeSettingChanged() {
    this.#scheduleComposerDraftSave()
  }

  prepareAttachmentSelection(event) {
    if (!this.submitInFlight) return

    const input = event?.currentTarget
    if (!input) return
    if (typeof DataTransfer !== "function") return

    this.pendingAttachmentRestoreFiles = Array.from(input.files || [])
    input.value = ""
  }

  keydown(event) {
    if (event.key !== "Enter") return
    if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return

    event.preventDefault()
    this.element.requestSubmit?.()
  }

  async submitEnd(event) {
    const success = event.detail?.success === true
    const submittedDraft = this.submittedDraft
    const submittedComposerDraftUpdatedAt = this.submittedComposerDraftUpdatedAt
    const submittedAttachmentSelectionToken = this.submittedAttachmentSelectionToken
    this.submittedDraft = null
    this.submittedComposerDraftUpdatedAt = null
    this.submittedAttachmentSelectionToken = null
    this.submitInFlight = false

    if (success) {
      this.pendingAttachmentRestoreFiles = null
      this.#clearComposerDraftIfUnchanged(submittedDraft, submittedAttachmentSelectionToken)
      this.#setComposerDraftUpdatedAt(submittedComposerDraftUpdatedAt)
      await this.#flushPendingSubmissions()
      return
    }

    this.#restorePendingSubmissions()
    this.#restorePendingAttachments()
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

    this.#scheduleComposerDraftSave()
  }

  cancelEdit(event) {
    event.preventDefault()
    this.#clearEditState()
    this.hasTextareaTarget && this.textareaTarget.focus()
    this.#scheduleComposerDraftSave()
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

    this.#scheduleComposerDraftSave()
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
    const token = this.#csrfToken()
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

  async #fetchTurboStream(url, { method, body }) {
    const token = this.#csrfToken()
    if (!token) return null

    return fetch(url, {
      method,
      headers: {
        "X-CSRF-Token": token,
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
        Accept: "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
      },
      body,
      credentials: "same-origin",
    })
  }

  #currentModelRef() {
    const modelSelect = this.element.querySelector('select[name="model_ref"]')
    return String(modelSelect?.value || "").trim()
  }

  #currentPermissionMode() {
    const permissionSelect = this.element.querySelector('select[name="conversation[permission_mode]"]')
    return String(permissionSelect?.value || "").trim()
  }

  #currentComposerDraftUpdatedAt() {
    const inputValue = this.hasComposerDraftUpdatedAtInputTarget ? this.composerDraftUpdatedAtInputTarget.value : ""
    return String(this.currentComposerDraftUpdatedAt || inputValue || "").trim()
  }

  #setComposerDraftUpdatedAt(value) {
    const normalizedValue = String(value || "").trim()
    this.currentComposerDraftUpdatedAt = normalizedValue
    if (this.hasComposerDraftUpdatedAtInputTarget) {
      this.composerDraftUpdatedAtInputTarget.value = normalizedValue
    }
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

  #csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
  }

  #scheduleComposerDraftSave() {
    if (!this.hasComposerDraftUrlValue) return

    this.#setComposerDraftUpdatedAt(new Date().toISOString())
    this.#clearDraftSaveTimer()
    this.pendingDraftSaveTimer = window.setTimeout(() => {
      this.pendingDraftSaveTimer = null
      void this.#saveComposerDraft()
    }, this.draftSaveDelayMs)
  }

  #clearDraftSaveTimer() {
    if (!this.pendingDraftSaveTimer) return
    window.clearTimeout(this.pendingDraftSaveTimer)
    this.pendingDraftSaveTimer = null
  }

  async #saveComposerDraft() {
    const response = await this.#fetchJson(this.composerDraftUrlValue, {
      method: "PATCH",
      body: {
        composer_draft: {
          content: this.hasTextareaTarget ? this.textareaTarget.value : "",
          model_ref: this.#currentModelRef(),
          permission_mode: this.#currentPermissionMode(),
          updated_at: this.#currentComposerDraftUpdatedAt(),
        },
      },
    })

    if (!response?.ok) {
      // Best-effort persistence. Keep the UI usable even if autosave fails.
    }
  }

  #captureSubmission(form) {
    const body = new FormData(form)
    const entries = []
    let content = ""

    for (const [key, value] of body.entries()) {
      if (typeof value !== "string") continue

      entries.push([key, value])
      if (key === "content") content = value
    }

    if (!content.trim()) return null

    return {
      action: form.action || this.defaultAction,
      entries,
      content,
    }
  }

  #clearComposerDraft({ clearAttachments = true } = {}) {
    this.#clearEditState()
    if (clearAttachments) this.#clearPendingAttachments()
    if (!this.hasTextareaTarget) return

    this.textareaTarget.value = ""
    this.autoResize()
    this.#syncComposerState()
  }

  #clearComposerDraftIfUnchanged(submittedDraft, submittedAttachmentSelectionToken = null) {
    this.#clearEditState()
    this.#clearPendingAttachmentsIfUnchanged(submittedAttachmentSelectionToken)
    if (!this.hasTextareaTarget) return

    const currentDraft = this.textareaTarget.value
    if (currentDraft.trim() && currentDraft !== String(submittedDraft || "")) {
      this.autoResize()
      this.#syncComposerState()
      return
    }

    this.textareaTarget.value = ""
    this.autoResize()
    this.#syncComposerState()
  }

  async #flushPendingSubmissions() {
    while (!this.submitInFlight && this.pendingSubmissions.length > 0) {
      const nextSubmission = this.pendingSubmissions.shift()
      const success = await this.#submitCapturedSubmission(nextSubmission)
      if (!success) break
    }
  }

  async #submitCapturedSubmission(submission) {
    if (!submission) return false

    this.submitInFlight = true

    try {
      const response = await this.#fetchTurboStream(submission.action, {
        method: "POST",
        body: new URLSearchParams(submission.entries),
      })
      if (!response?.ok) {
        this.pendingSubmissions.unshift(submission)
        this.#showToast("Queued send failed.")
        return false
      }

      const stream = await response.text()
      if (stream && window.Turbo?.renderStreamMessage) {
        window.Turbo.renderStreamMessage(stream)
      }

      this.#clearComposerDraftIfUnchanged(submission.content)
      return true
    } catch (_error) {
      this.pendingSubmissions.unshift(submission)
      this.#showToast("Queued send failed.")
      return false
    } finally {
      this.submitInFlight = false
    }
  }

  #restorePendingSubmissions() {
    if (!this.hasTextareaTarget) return
    if (this.pendingSubmissions.length === 0) return

    const currentDraft = this.textareaTarget.value
    const restored = [...this.pendingSubmissions.map(({ content }) => String(content || "")), currentDraft]
      .map((value) => value.trim())
      .filter(Boolean)
      .join("\n")

    this.pendingSubmissions = []
    this.textareaTarget.value = restored
    this.autoResize()
    this.textareaTarget.focus()
  }

  #restorePendingAttachments() {
    if (!this.hasAttachmentInputTarget) {
      this.pendingAttachmentRestoreFiles = null
      return
    }

    const files = Array.from(this.pendingAttachmentRestoreFiles || [])
    if (files.length === 0) return
    if (this.attachmentInputTarget.files.length > 0) {
      this.pendingAttachmentRestoreFiles = null
      return
    }
    if (typeof DataTransfer !== "function") {
      this.pendingAttachmentRestoreFiles = null
      return
    }

    try {
      const transfer = new DataTransfer()
      files.forEach((file) => transfer.items.add(file))
      this.attachmentInputTarget.files = transfer.files
    } finally {
      this.pendingAttachmentRestoreFiles = null
    }
  }

  #clearPendingAttachments() {
    if (!this.hasAttachmentInputTarget) return

    this.attachmentInputTarget.value = ""
  }

  #clearPendingAttachmentsIfUnchanged(submittedAttachmentSelectionToken) {
    const currentSelectionToken = this.#currentAttachmentSelectionToken()
    if (submittedAttachmentSelectionToken !== currentSelectionToken) return

    this.#clearPendingAttachments()
  }

  #hasPendingAttachments() {
    return this.hasAttachmentInputTarget && this.attachmentInputTarget.files.length > 0
  }

  #hasPendingAttachmentsForNewSubmission() {
    if (!this.#hasPendingAttachments()) return false
    if (!this.submitInFlight) return true

    return this.#currentAttachmentSelectionToken() !== this.submittedAttachmentSelectionToken
  }

  #currentAttachmentSelectionToken() {
    if (!this.#hasPendingAttachments()) return null

    return this.attachmentSelectionToken
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
