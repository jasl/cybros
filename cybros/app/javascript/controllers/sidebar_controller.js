import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle"]
  static values = {
    key: String,
  }

  connect() {
    if (!this.hasToggleTarget || !this.keyValue) return

    const stored = window.localStorage.getItem(this.#storageKey())
    if (stored === "open") this.toggleTarget.checked = true
    if (stored === "closed") this.toggleTarget.checked = false

    if (stored == null) {
      const isDesktop = window.matchMedia?.("(min-width: 1024px)")?.matches
      if (isDesktop) {
        this.toggleTarget.checked = true
      }
    }

    this.toggleTarget.addEventListener("change", this.#onChange, { passive: true })
  }

  disconnect() {
    if (!this.hasToggleTarget) return
    this.toggleTarget.removeEventListener("change", this.#onChange)
  }

  #onChange = () => {
    if (!this.keyValue) return
    window.localStorage.setItem(this.#storageKey(), this.toggleTarget.checked ? "open" : "closed")
  }

  #storageKey() {
    return `cybros:sidebar:v2:${this.keyValue}`
  }
}

