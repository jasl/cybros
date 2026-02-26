import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["link"]

  connect() {
    const currentPath = window.location?.pathname
    if (!currentPath) return

    for (const el of this.linkTargets) {
      const href = el.getAttribute("href")
      if (!href || href === "#") continue
      if (href === currentPath || currentPath.startsWith(`${href}/`)) {
        el.classList.add("menu-active")
      }
    }
  }
}

