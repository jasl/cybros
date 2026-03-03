import { dismiss } from "./animation"

export function startCountdown(controller) {
  controller.startTime = performance.now()
  updateProgress(controller)
}

export function updateProgress(controller) {
  if (controller.isPaused) return

  const elapsed = performance.now() - controller.startTime
  const remaining = controller.remainingTime - elapsed

  if (remaining <= 0) {
    dismiss(controller)
    return
  }

  if (controller.hasProgressTarget) {
    const percentage = (remaining / controller.durationValue) * 100
    controller.progressTarget.style.width = `${percentage}%`
  }

  controller.animationFrameId = requestAnimationFrame(() => updateProgress(controller))
}

export function pause(controller) {
  if (!controller.autoDismissValue || controller.isPaused) return

  controller.isPaused = true
  const elapsed = performance.now() - controller.startTime
  controller.remainingTime = Math.max(0, controller.remainingTime - elapsed)

  if (controller.animationFrameId) {
    cancelAnimationFrame(controller.animationFrameId)
    controller.animationFrameId = null
  }
}

export function resume(controller) {
  if (!controller.autoDismissValue || !controller.isPaused) return

  controller.isPaused = false
  controller.startTime = performance.now()
  updateProgress(controller)
}

export function clearTimers(controller) {
  if (controller.animationFrameId) {
    cancelAnimationFrame(controller.animationFrameId)
    controller.animationFrameId = null
  }
}

