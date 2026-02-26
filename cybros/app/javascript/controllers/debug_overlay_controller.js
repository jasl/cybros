import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "cursor", "activeNode", "lastEvent"]

  connect() {
    this.visible = false
    this.#syncVisibility()
    this.onKeydown = (e) => {
      if (!(e.ctrlKey || e.metaKey) || !e.shiftKey || e.key.toLowerCase() !== "d") return
      e.preventDefault()
      this.visible = !this.visible
      this.#syncVisibility()
    }
    window.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    window.removeEventListener("keydown", this.onKeydown)
  }

  update(event) {
    const d = event.detail || {}
    if (this.hasCursorTarget) this.cursorTarget.textContent = String(d.cursor || "")
    if (this.hasActiveNodeTarget) this.activeNodeTarget.textContent = String(d.activeNodeId || d.lastErroredNodeId || "")
    if (this.hasLastEventTarget) {
      const ts = typeof d.lastEventAt === "number" ? new Date(d.lastEventAt).toISOString() : ""
      this.lastEventTarget.textContent = ts
    }
  }

  #syncVisibility() {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.toggle("hidden", !this.visible)
  }
}

