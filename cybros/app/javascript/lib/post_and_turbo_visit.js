function csrfToken(documentLike = document) {
  return documentLike.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
}

function formUrlEncodedBody(params) {
  const body = new URLSearchParams()
  for (const [k, v] of Object.entries(params || {})) body.set(k, String(v ?? ""))
  return body
}

function formPostOptions(params, { token, accept }) {
  return {
    method: "POST",
    headers: {
      "X-CSRF-Token": token,
      "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
      Accept: accept,
    },
    body: formUrlEncodedBody(params),
    credentials: "same-origin",
  }
}

export async function postAndTurboVisit(
  url,
  params,
  { documentLike = document, turbo = window.Turbo, windowLike = window, preserveScroll = false, fetchImpl = fetch } = {},
) {
  const token = csrfToken(documentLike)
  if (!token) return

  let res
  try {
    res = await fetchImpl(url, { ...formPostOptions(params, { token, accept: "text/html" }), redirect: "follow" })
  } catch (_e) {
    return
  }

  if (!res || !res.ok) return

  const nextUrl = res.url || ""
  if (!nextUrl) return

  const currentUrl = windowLike.location.href
  const isSame = currentUrl === nextUrl

  if (turbo?.visit) {
    if (preserveScroll && isSame && typeof documentLike.addEventListener === "function") {
      const restoreX = Number(windowLike.scrollX || 0)
      const restoreY = Number(windowLike.scrollY || 0)
      const restoreScroll = () => {
        documentLike.removeEventListener?.("turbo:load", restoreScroll)
        const run = () => windowLike.scrollTo?.(restoreX, restoreY)
        if (typeof windowLike.requestAnimationFrame === "function") {
          windowLike.requestAnimationFrame(run)
        } else {
          run()
        }
      }

      documentLike.addEventListener("turbo:load", restoreScroll)
    }

    // Use `replace` so same-URL redirects still refresh the page.
    turbo.visit(nextUrl, { action: "replace" })
  } else if (isSame) {
    windowLike.location.reload()
  } else {
    windowLike.location.href = nextUrl
  }
}

export async function postAndRenderTurboStream(
  url,
  params,
  { documentLike = document, turbo = window.Turbo, fetchImpl = fetch } = {},
) {
  const token = csrfToken(documentLike)
  if (!token) return false

  let res
  try {
    res = await fetchImpl(url, formPostOptions(params, { token, accept: "text/vnd.turbo-stream.html" }))
  } catch (_e) {
    return false
  }

  if (!res || !res.ok) return false

  const html = await res.text().catch(() => "")
  if (!html || !html.includes("<turbo-stream")) return false

  turbo?.renderStreamMessage?.(html)
  return true
}
