import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle"]
  static values = {
    key: String,
  }

  connect() {
    this.reapplyAnimationFrame = null
    document.addEventListener("turbo:render", this.#reapplyAfterTurbo)
    document.addEventListener("turbo:load", this.#reapplyAfterTurbo)

    if (!this.hasToggleTarget || !this.keyValue) return
    this.#applyStoredState(this.toggleTarget)
  }

  disconnect() {
    document.removeEventListener("turbo:render", this.#reapplyAfterTurbo)
    document.removeEventListener("turbo:load", this.#reapplyAfterTurbo)
    this.#cancelScheduledApply()

    if (!this.hasToggleTarget) return
    this.toggleTarget.removeEventListener("change", this.#onChange)
  }

  toggleTargetConnected(element) {
    if (!this.keyValue) return

    element.removeEventListener("change", this.#onChange)
    element.addEventListener("change", this.#onChange, { passive: true })
    this.#applyStoredState(element)
  }

  toggleTargetDisconnected(element) {
    element.removeEventListener("change", this.#onChange)
  }

  #onChange = () => {
    if (!this.keyValue) return
    window.localStorage.setItem(this.#storageKey(), this.toggleTarget.checked ? "open" : "closed")
  }

  #reapplyAfterTurbo = () => {
    if (!this.hasToggleTarget || !this.keyValue) return

    this.#cancelScheduledApply()
    this.reapplyAnimationFrame = window.requestAnimationFrame(() => {
      this.reapplyAnimationFrame = null
      if (!this.hasToggleTarget || !this.toggleTarget.isConnected) return
      this.#applyStoredState(this.toggleTarget)
    })
  }

  #storageKey() {
    return `cybros:sidebar:v2:${this.keyValue}`
  }

  #cancelScheduledApply() {
    if (this.reapplyAnimationFrame === null) return
    window.cancelAnimationFrame(this.reapplyAnimationFrame)
    this.reapplyAnimationFrame = null
  }

  #applyStoredState(toggle) {
    const stored = window.localStorage.getItem(this.#storageKey())
    if (stored === "open") {
      toggle.checked = true
      return
    }

    if (stored === "closed") {
      toggle.checked = false
      return
    }

    const isDesktop = window.matchMedia?.("(min-width: 1024px)")?.matches
    if (isDesktop) {
      toggle.checked = true
    }
  }
}
