function csrfToken(documentLike = document) {
  return documentLike.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
}

function formUrlEncodedBody(params) {
  const body = new URLSearchParams()
  for (const [k, v] of Object.entries(params || {})) body.set(k, String(v ?? ""))
  return body
}

export async function postAndTurboVisit(url, params, { documentLike = document, turbo = window.Turbo } = {}) {
  const token = csrfToken(documentLike)
  if (!token) return

  const body = formUrlEncodedBody(params)

  let res
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        "X-CSRF-Token": token,
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
        Accept: "text/html",
      },
      body,
      credentials: "same-origin",
      redirect: "follow",
    })
  } catch (_e) {
    return
  }

  if (!res || !res.ok) return

  const nextUrl = res.url || ""
  if (!nextUrl) return

  const currentUrl = window.location.href
  const isSame = currentUrl === nextUrl

  if (turbo?.visit) {
    // Use `replace` so same-URL redirects still refresh the page.
    turbo.visit(nextUrl, { action: "replace" })
  } else if (isSame) {
    window.location.reload()
  } else {
    window.location.href = nextUrl
  }
}
