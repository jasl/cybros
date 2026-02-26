import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "sentinel"]
  static values = { url: String }

  connect() {
    if (!this.urlValue) return

    this.loading = false
    this.observer = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting) this.loadMore()
      },
      { root: this.element }
    )

    if (this.hasSentinelTarget) {
      this.observer.observe(this.sentinelTarget)
    }
  }

  disconnect() {
    this.observer?.disconnect()
  }

  async loadMore() {
    if (this.loading || !this.urlValue) return
    this.loading = true

    try {
      const response = await fetch(this.urlValue, {
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest",
        },
        credentials: "same-origin",
      })

      if (!response.ok) return

      const html = await response.text()
      const nextUrl = response.headers.get("X-Next-Page")

      this.listTarget.insertAdjacentHTML("beforeend", html)

      if (nextUrl) {
        this.urlValue = nextUrl
      } else {
        this.sentinelTarget.remove()
        this.observer?.disconnect()
      }
    } finally {
      this.loading = false
    }
  }

  urlValueChanged() {
    if (this.hasSentinelTarget && this.observer) {
      this.observer.unobserve(this.sentinelTarget)
      this.observer.observe(this.sentinelTarget)
    }
  }
}
