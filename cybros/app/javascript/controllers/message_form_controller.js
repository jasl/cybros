import { Controller } from "@hotwired/stimulus"
import {
  deriveComposerFormState,
  deriveComposerPreviewText,
  normalizeComposerRailState,
} from "../lib/conversation_composer_state"

export default class extends Controller {
  static targets = [
    "textarea",
    "statusRail",
    "queueModeButton",
    "steerModeButton",
    "previewText",
    "previewEmpty",
    "previewSourceLabel",
    "runningInputPolicyInput",
  ]

  connect() {
    this.defaultAction = this.element.action
    this.selectedMode = null
    this.autoResize()
    this.#syncComposerState()
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

    this.textareaTarget.value = ""
    this.selectedMode = null
    this.autoResize()
    this.#syncComposerState()
  }

  autoResize() {
    if (!this.hasTextareaTarget) return
    const el = this.textareaTarget
    el.style.height = "auto"
    el.style.height = `${el.scrollHeight}px`
    this.#syncPreview()
  }

  selectQueueMode(event) {
    event.preventDefault()
    this.selectedMode = "queue"
    this.#syncComposerState()
  }

  selectSteerMode(event) {
    event.preventDefault()
    this.selectedMode = "steer_current_turn"
    this.#syncComposerState()
  }

  #syncComposerState() {
    const railState = this.#railState()
    const formState = deriveComposerFormState({
      railState,
      selectedMode: this.selectedMode,
    })

    this.selectedMode = formState.resolvedMode
    this.element.action = formState.formAction || this.defaultAction

    if (this.hasRunningInputPolicyInputTarget) {
      const value = formState.runningInputPolicyOverride
      this.runningInputPolicyInputTarget.value = value || ""
      this.runningInputPolicyInputTarget.disabled = !value
    }

    this.#renderModeButtons(railState, formState)
    this.#syncPreview(railState)
  }

  #railState() {
    if (!this.hasStatusRailTarget) {
      return normalizeComposerRailState({ createUrl: this.defaultAction })
    }

    return normalizeComposerRailState(this.statusRailTarget.dataset)
  }

  #renderModeButtons(railState, formState) {
    if (this.hasQueueModeButtonTarget) {
      this.#renderModeButton(this.queueModeButtonTarget, {
        selected: formState.resolvedMode === "queue",
        disabled: !railState.running,
        title: railState.running ? "" : railState.steerReason,
      })
    }

    if (this.hasSteerModeButtonTarget) {
      this.#renderModeButton(this.steerModeButtonTarget, {
        selected: formState.resolvedMode === "steer_current_turn",
        disabled: !railState.steerAvailable,
        title: railState.steerReason,
      })
    }
  }

  #renderModeButton(button, { selected, disabled, title }) {
    button.classList.toggle("btn-neutral", selected)
    button.classList.toggle("text-base-content/70", !selected)
    button.classList.toggle("border-base-content/15", !selected)
    button.classList.toggle("btn-disabled", disabled)
    button.disabled = disabled
    button.setAttribute("aria-pressed", selected ? "true" : "false")

    if (title) button.title = title
    else button.removeAttribute("title")
  }

  #syncPreview(railState = this.#railState()) {
    const draft = this.hasTextareaTarget ? this.textareaTarget.value : ""
    const preview = deriveComposerPreviewText({
      draft,
      queuedPreview: railState.candidatePreview,
    })

    if (this.hasPreviewTextTarget) {
      this.previewTextTarget.textContent = preview.content
      this.previewTextTarget.classList.toggle("hidden", !preview.content)
    }

    if (this.hasPreviewEmptyTarget) {
      this.previewEmptyTarget.classList.toggle("hidden", !!preview.content)
    }

    if (this.hasPreviewSourceLabelTarget) {
      this.previewSourceLabelTarget.textContent =
        preview.source === "draft" ? "Draft" : preview.source === "queued_turn" ? "Queued turn" : ""
    }
  }
}
