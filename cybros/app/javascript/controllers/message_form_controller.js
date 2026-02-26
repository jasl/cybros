import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea"]

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
  }

  keydown(event) {
    if (event.key !== "Enter") return
    if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return

    event.preventDefault()
    this.element.requestSubmit?.()
  }

  autoResize() {
    if (!this.hasTextareaTarget) return
    const el = this.textareaTarget
    el.style.height = "auto"
    el.style.height = `${el.scrollHeight}px`
  }
}
