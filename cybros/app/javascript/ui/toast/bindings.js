import { getAnimatedElement, show } from "./animation"
import { clearTimers, pause, resume, startCountdown } from "./countdown"

export function connect(controller) {
  controller.remainingTime = controller.durationValue
  controller.isPaused = false
  controller.startTime = null
  controller.animationFrameId = null

  controller.boundPause = () => pause(controller)
  controller.boundResume = () => resume(controller)
  controller.hoverElement = null

  show(controller)

  if (controller.autoDismissValue && controller.durationValue > 0) {
    startCountdown(controller)

    if (controller.pauseOnHoverValue) {
      controller.hoverElement = getAnimatedElement(controller)
      controller.hoverElement.addEventListener("mouseenter", controller.boundPause)
      controller.hoverElement.addEventListener("mouseleave", controller.boundResume)
    }
  }
}

export function disconnect(controller) {
  clearTimers(controller)

  if (controller.pauseOnHoverValue && controller.hoverElement) {
    controller.hoverElement.removeEventListener("mouseenter", controller.boundPause)
    controller.hoverElement.removeEventListener("mouseleave", controller.boundResume)
    controller.hoverElement = null
  }
}

