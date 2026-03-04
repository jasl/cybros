const SAFE_LINK_PROTOCOLS = new Set(["http:", "https:", "mailto:", "tel:"])
const SAFE_IMAGE_PROTOCOLS = new Set(["http:", "https:"])

export function sanitizeLinkUrl(href) {
  return sanitizeUrl(href, SAFE_LINK_PROTOCOLS)
}

export function sanitizeImageUrl(href) {
  return sanitizeUrl(href, SAFE_IMAGE_PROTOCOLS)
}

function sanitizeUrl(href, allowedProtocols) {
  if (!href) return null
  try {
    const url = new URL(String(href), window.location.href)
    if (!allowedProtocols.has(url.protocol)) return null
    return url
  } catch {
    return null
  }
}

