import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox"]

  connect() {
    const currentTheme = document.documentElement.getAttribute("data-theme") || "light"
    if (this.hasCheckboxTarget) {
      this.checkboxTarget.checked = currentTheme === "dark"
    }
  }

  toggle() {
    const isDark = this.hasCheckboxTarget ? this.checkboxTarget.checked : false
    const newTheme = isDark ? "dark" : "light"
    document.documentElement.setAttribute("data-theme", newTheme)
    localStorage.setItem("theme", newTheme)
  }
}

