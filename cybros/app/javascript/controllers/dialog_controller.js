import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { id: String }

  open(event) {
    event?.preventDefault()
    const dialog = this.#findDialog()
    if (!dialog || dialog.open) return
    dialog.showModal()
  }

  close(event) {
    event?.preventDefault()
    const dialog = this.#findDialog()
    if (!dialog || !dialog.open) return
    dialog.close()
  }

  #findDialog() {
    const id = this.idValue
    if (id) {
      const dialog = document.getElementById(id)
      return dialog instanceof HTMLDialogElement ? dialog : null
    }

    const dialog = this.element.closest("dialog")
    return dialog instanceof HTMLDialogElement ? dialog : null
  }
}
