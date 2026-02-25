import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["pre"]
  static values = {
    directiveId: String,
    stream: String,
    pollMs: { type: Number, default: 1000 },
  }

  connect() {
    this.afterSeq = -1
    this.polling = true
    this.poll()
  }

  disconnect() {
    this.polling = false
  }

  async poll() {
    if (!this.polling) return

    try {
      const url = `/mothership/directives/${encodeURIComponent(this.directiveIdValue)}/log?stream=${encodeURIComponent(
        this.streamValue
      )}&after_seq=${this.afterSeq}&limit=200`

      const resp = await fetch(url, { headers: { Accept: "application/json" } })
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`)

      const data = await resp.json()
      if (Array.isArray(data.chunks)) {
        for (const chunk of data.chunks) {
          if (!chunk.bytes_base64) continue
          this.preTarget.textContent += this.decodeBase64(chunk.bytes_base64)
        }
      }

      if (typeof data.next_after_seq === "number") {
        this.afterSeq = data.next_after_seq
      }
    } catch (e) {
      // Swallow errors: this is a best-effort viewer for an experimental UI.
      // The next poll will retry.
    } finally {
      if (!this.polling) return
      setTimeout(() => this.poll(), this.pollMsValue)
    }
  }

  decodeBase64(b64) {
    const bin = atob(b64)
    const bytes = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
    return new TextDecoder().decode(bytes)
  }
}
