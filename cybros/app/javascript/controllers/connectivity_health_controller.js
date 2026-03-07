import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["disconnectedAlert", "disconnectedDetail"]

  connect() {
    this.disconnectHealthTimer = null
    this.disconnectHealthAttempts = 0
    this.disconnectHealthGeneration = 0
    this.everConnected = false

    this.attributeObserver = new MutationObserver(() => this.#reconcile())
    this.attributeObserver.observe(this.element, { attributes: true, attributeFilter: ["data-conversation-channel-connected"] })

    this.#reconcile()
  }

  disconnect() {
    this.attributeObserver?.disconnect?.()
    this.attributeObserver = null

    this.#clearDisconnectHealthTimer()
  }

  #reconcile() {
    const connected = String(this.element.getAttribute("data-conversation-channel-connected") || "false") === "true"
    if (connected) {
      this.everConnected = true
      this.#hideDisconnected()
      this.#clearDisconnectHealthTimer()
    } else {
      // Avoid a banner flash on initial page load. Only show disconnect UX after we've
      // observed at least one successful connection during this page lifecycle.
      if (!this.everConnected) {
        this.#hideDisconnected()
        this.#clearDisconnectHealthTimer()
        return
      }

      this.#showDisconnected()
      this.#startDisconnectHealthTimer()
    }
  }

  #showDisconnected() {
    if (this.hasDisconnectedAlertTarget) this.disconnectedAlertTarget.classList.remove("hidden")
  }

  #hideDisconnected() {
    if (this.hasDisconnectedAlertTarget) this.disconnectedAlertTarget.classList.add("hidden")
    if (this.hasDisconnectedDetailTarget) this.disconnectedDetailTarget.textContent = ""
  }

  #startDisconnectHealthTimer() {
    if (this.disconnectHealthTimer) return

    const generation = (this.disconnectHealthGeneration || 0) + 1
    this.disconnectHealthGeneration = generation

    // Exponential-ish backoff: 1s, 2s, 4s, 8s, then cap at 15s.
    const tick = async () => {
      if (!this.disconnectHealthTimer) return
      if (this.disconnectHealthGeneration !== generation) return

      const attempt = this.disconnectHealthAttempts
      const delay = Math.min(1000 * 2 ** attempt, 15000)
      this.disconnectHealthAttempts = Math.min(attempt + 1, 10)

      await this.#pingUp()
      if (!this.disconnectHealthTimer) return
      if (this.disconnectHealthGeneration !== generation) return
      this.disconnectHealthTimer = window.setTimeout(tick, delay)
    }

    this.disconnectHealthAttempts = 0
    this.disconnectHealthTimer = window.setTimeout(tick, 500)
  }

  #clearDisconnectHealthTimer() {
    if (!this.disconnectHealthTimer) return
    window.clearTimeout(this.disconnectHealthTimer)
    this.disconnectHealthTimer = null
    this.disconnectHealthAttempts = 0
    this.disconnectHealthGeneration = (this.disconnectHealthGeneration || 0) + 1
  }

  async #pingUp() {
    if (!this.hasDisconnectedDetailTarget) return

    try {
      const res = await fetch("/up", { method: "GET", credentials: "same-origin" })
      if (res.ok) {
        this.disconnectedDetailTarget.textContent = "(server reachable)"
      } else {
        this.disconnectedDetailTarget.textContent = `(server error: ${res.status})`
      }
    } catch (_e) {
      this.disconnectedDetailTarget.textContent = "(server unreachable)"
    }
  }
}
