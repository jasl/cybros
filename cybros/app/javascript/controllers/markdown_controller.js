import { Controller } from "@hotwired/stimulus"
import { marked } from "marked"
import { escapeHtml } from "../lib/escape_html"
import { sanitizeImageUrl, sanitizeLinkUrl } from "../lib/safe_url"

let markedConfigured = false

function configureMarkedOnce() {
  if (markedConfigured) return

  const renderer = new marked.Renderer()

  // Disallow raw HTML from user content (XSS mitigation).
  renderer.html = (html) => escapeHtml(html)

  // Sanitize links to block javascript:/data: etc.
  renderer.link = (href, title, text) => {
    const url = sanitizeLinkUrl(href)
    const safeText = escapeHtml(text)
    if (!url) return safeText

    const isExternal = url.origin !== window.location.origin
    const safeHref = escapeHtml(url.toString())
    const safeTitle = title ? ` title="${escapeHtml(title)}"` : ""
    const externalAttrs = isExternal ? ` target="_blank" rel="nofollow noreferrer noopener"` : ""

    return `<a href="${safeHref}"${safeTitle}${externalAttrs}>${safeText}</a>`
  }

  // Allow only http(s) images (blocks data: and other schemes).
  renderer.image = (href, title, text) => {
    const url = sanitizeImageUrl(href)
    if (!url) return ""

    const safeSrc = escapeHtml(url.toString())
    const safeAlt = escapeHtml(text)
    const safeTitle = title ? ` title="${escapeHtml(title)}"` : ""

    return `<img src="${safeSrc}" alt="${safeAlt}" loading="lazy" referrerpolicy="no-referrer"${safeTitle} />`
  }

  // Do not trust/propagate user-controlled "language" strings into class attributes.
  // Keep code blocks plain and escaped.
  renderer.code = (code) => {
    return `<pre><code>${escapeHtml(code)}</code></pre>`
  }

  renderer.codespan = (code) => {
    return `<code>${escapeHtml(code)}</code>`
  }

  marked.setOptions({
    gfm: true,
    breaks: true,
    pedantic: false,
    headerIds: false,
    mangle: false,
    renderer,
  })

  markedConfigured = true
}

function parseMarkdown(text) {
  try {
    return marked.parse(String(text ?? ""))
  } catch {
    return escapeHtml(text)
  }
}

export default class extends Controller {
  static targets = ["content", "output"]

  connect() {
    configureMarkedOnce()
    this.lastRenderedRaw = null
    this.renderNow()
  }

  renderNow() {
    const raw = this.#getRawContent()
    if (!raw) return
    if (this.lastRenderedRaw === raw) return

    const html = parseMarkdown(raw)
    this.outputTarget.innerHTML = html
    this.lastRenderedRaw = raw
  }

  #getRawContent() {
    if (!this.hasContentTarget) return ""
    const el = this.contentTarget

    if (el.tagName === "TEMPLATE") {
      return el.content.textContent || ""
    }
    return el.textContent || ""
  }
}

