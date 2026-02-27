import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "list"]

  filter() {
    if (!this.hasListTarget) return

    const query = this.inputTarget.value.toLowerCase().trim()
    const items = this.listTarget.querySelectorAll(":scope > li")

    items.forEach((item) => {
      if (query === "") {
        item.hidden = false
      } else {
        const text = item.textContent.toLowerCase()
        item.hidden = !text.includes(query)
      }
    })
  }
}
