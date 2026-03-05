import { Controller } from "@hotwired/stimulus"
import { dismiss } from "../ui/toast/animation"
import { connect, disconnect } from "../ui/toast/bindings"
import { clearTimers } from "../ui/toast/countdown"

export default class extends Controller {
  static targets = ["alert", "progress"]

  static values = {
    duration: { type: Number, default: 5000 },
    autoDismiss: { type: Boolean, default: true },
    pauseOnHover: { type: Boolean, default: true },
  }

  connect() {
    connect(this)
  }

  disconnect() {
    disconnect(this)
  }

  dismiss() {
    clearTimers(this)
    dismiss(this)
  }
}
