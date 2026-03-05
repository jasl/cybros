import { Controller } from "@hotwired/stimulus"
import { marked } from "marked"
import { escapeHtml } from "../lib/escape_html"
import { sanitizeImageUrl, sanitizeLinkUrl } from "../lib/safe_url"

let markedConfigured = false

function tokensToPlainText(tokens) {
  if (!Array.isArray(tokens)) return ""

  let out = ""
  for (const t of tokens) {
    if (!t || typeof t !== "object") continue
    if (typeof t.text === "string") out += t.text
    if (Array.isArray(t.tokens)) out += tokensToPlainText(t.tokens)
  }
  return out
}

function configureMarkedOnce() {
  if (markedConfigured) return

  marked.setOptions({
    gfm: true,
    breaks: true,
    pedantic: false,
  })

  marked.use({
    renderer: {
      // Disallow raw HTML from user content (XSS mitigation).
      html({ text }) {
        return escapeHtml(text)
      },

      // Keep headings deterministic and avoid id generation.
      heading({ depth, tokens }) {
        const d = Number(depth)
        const safeDepth = Number.isFinite(d) ? Math.min(Math.max(d, 1), 6) : 1
        const label = escapeHtml(tokensToPlainText(tokens))
        return `<h${safeDepth}>${label}</h${safeDepth}>`
      },

      // Sanitize links to block javascript:/data: etc.
      link({ href, title, tokens, text }) {
        const url = sanitizeLinkUrl(href)
        const label = text ?? tokensToPlainText(tokens)
        const safeText = escapeHtml(label)
        if (!url) return safeText

        const isExternal = url.origin !== window.location.origin
        const safeHref = escapeHtml(url.toString())
        const safeTitle = title ? ` title="${escapeHtml(title)}"` : ""
        const externalAttrs = isExternal ? ` target="_blank" rel="nofollow noreferrer noopener"` : ""

        return `<a href="${safeHref}"${safeTitle}${externalAttrs}>${safeText}</a>`
      },

      // Allow only http(s) images (blocks data: and other schemes).
      image({ href, title, text }) {
        const url = sanitizeImageUrl(href)
        if (!url) return ""

        const safeSrc = escapeHtml(url.toString())
        const safeAlt = escapeHtml(text)
        const safeTitle = title ? ` title="${escapeHtml(title)}"` : ""

        return `<img src="${safeSrc}" alt="${safeAlt}" loading="lazy" referrerpolicy="no-referrer"${safeTitle} />`
      },

      // Do not trust/propagate user-controlled "language" strings into class attributes.
      // Keep code blocks plain and escaped.
      code({ text }) {
        return `<pre><code>${escapeHtml(text)}</code></pre>`
      },

      codespan({ text }) {
        return `<code>${escapeHtml(text)}</code>`
      },
    },
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
