import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "icon"]
  static values = { open: { type: Boolean, default: true } }

  toggle() {
    this.openValue = !this.openValue
  }

  openValueChanged() {
    if (this.hasContentTarget) {
      this.contentTarget.hidden = !this.openValue
    }
    if (this.hasIconTarget) {
      this.iconTarget.style.transform = this.openValue ? "" : "rotate(-90deg)"
    }
  }
}
