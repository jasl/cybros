// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import "./controllers"
import "./channels"

// Global toast handler
// Listens for `toast:show` custom events and displays toast notifications.
// Uses the toast template from `app/views/_shared/_js_templates.html.erb`.
window.addEventListener("toast:show", (event) => {
  const { message, type = "info", duration = 5000 } = event.detail || {}
  if (!message) return

  const template = document.getElementById("toast_template")
  const container = document.getElementById("toast_container")
  if (!template || !container) return

  const toast = template.content.cloneNode(true).firstElementChild
  if (!toast) return

  const normalizedType = String(type || "info")
  const alertClass =
    {
      info: "alert-info",
      success: "alert-success",
      notice: "alert-success",
      warning: "alert-warning",
      error: "alert-error",
      alert: "alert-error",
    }[normalizedType] || "alert-info"

  const iconClass =
    {
      info: "icon-[lucide--info]",
      success: "icon-[lucide--check-circle]",
      notice: "icon-[lucide--check-circle]",
      warning: "icon-[lucide--alert-triangle]",
      error: "icon-[lucide--x-circle]",
      alert: "icon-[lucide--x-circle]",
    }[normalizedType] || "icon-[lucide--info]"

  const alert = toast.querySelector("[data-toast-target='alert']")
  if (alert) alert.classList.add(alertClass)

  const icon = toast.querySelector("[data-toast-icon]")
  if (icon) icon.className = `${iconClass} size-5 shrink-0`

  const messageNode = toast.querySelector("[data-toast-message]")
  if (messageNode) messageNode.textContent = message

  toast.dataset.toastDurationValue = String(duration)
  container.appendChild(toast)
})
