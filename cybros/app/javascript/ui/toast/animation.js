export function getAnimatedElement(controller) {
  return controller.hasAlertTarget ? controller.alertTarget : controller.element
}

export function getEnterTransform() {
  return "translateX(120%)"
}

export function show(controller) {
  const el = getAnimatedElement(controller)
  const enterTransform = getEnterTransform()

  el.style.transition = "none"
  el.style.willChange = "opacity, transform"
  el.style.opacity = "0"
  el.style.transform = enterTransform

  requestAnimationFrame(() => {
    el.style.transition = "opacity 300ms ease-out, transform 300ms ease-out"
    el.style.opacity = "1"
    el.style.transform = "translate3d(0, 0, 0)"
  })
}

export function dismiss(controller) {
  const el = getAnimatedElement(controller)
  const exitTransform = getEnterTransform()

  el.style.transition = "opacity 200ms ease-in, transform 200ms ease-in"
  el.style.opacity = "0"
  el.style.transform = exitTransform

  const remove = () => controller.element.remove()
  el.addEventListener("transitionend", remove, { once: true })
  setTimeout(remove, 250)
}

