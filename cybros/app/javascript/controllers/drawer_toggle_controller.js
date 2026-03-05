import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  onKeydown(event) {
    if (event.key !== "Enter" && event.key !== " ") return

    event.preventDefault()

    const targetId = this.element.getAttribute("for")
    if (!targetId) return

    const input = document.getElementById(targetId)
    if (!(input instanceof HTMLInputElement)) return

    input.click()
  }
}
