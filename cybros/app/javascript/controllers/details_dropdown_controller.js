import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.#handler = (event) => {
      if (this.element.open && !this.element.contains(event.target)) {
        this.element.open = false
      }
    }
    document.addEventListener("click", this.#handler, true)
  }

  disconnect() {
    document.removeEventListener("click", this.#handler, true)
  }

  #handler
}
