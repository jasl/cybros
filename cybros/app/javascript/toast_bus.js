export function showToast(message, type = "info", duration = 5000) {
  if (!message) return

  window.dispatchEvent(new CustomEvent("toast:show", {
    detail: { message, type, duration },
    bubbles: true,
    cancelable: true,
  }))
}

