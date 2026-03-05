import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider } from "./helpers"

test.describe("Conversation mock LLM: stop flow", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
    await createHighPriorityMockProvider(page)
  })

  test("slow streaming run can be stopped; conversation remains usable", async ({ page }) => {
    test.setTimeout(180_000)

    await page.goto("/conversations")
    await page.locator("main").getByPlaceholder("New conversation title").fill(`E2E Stop ${Date.now()}`)
    await page.locator("main").getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    // Make the completion take long enough to reliably click Stop.
    // Keep the run long enough to stop reliably, but short enough that a failed stop doesn't
    // stall the entire E2E suite.
    const longPrompt = "x".repeat(1200)
    const content = `!mock slow=0.03 -- ${longPrompt}`

    await page.getByPlaceholder("Message…").fill(content)
    await page.getByRole("button", { name: "Send" }).click()

    await expect(page.getByText(content)).toBeVisible({ timeout: 10_000 })

    const agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper).toBeVisible()

    const messageId = await agentWrapper.getAttribute("id")
    expect(messageId).toBeTruthy()
    if (!messageId) throw new Error("missing message wrapper id")

    const nodeIdToStop = messageId.replace(/^message_/, "")
    const conversationId = new URL(page.url()).pathname.split("/").pop()
    expect(conversationId).toBeTruthy()
    if (!conversationId) throw new Error("missing conversation id")

    // Stop via endpoint once the node is actually running (the controller rejects pending).
    // This avoids coupling to flaky realtime UI toggles while still exercising the real stop action.
    const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content")
    if (!csrf) throw new Error("missing csrf token")

    const stopDeadline = Date.now() + 60_000
    let stoppedOk = false
    while (Date.now() < stopDeadline) {
      const res = await page.request.post(`/conversations/${conversationId}/stop`, {
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json", Accept: "application/json" },
        data: { node_id: nodeIdToStop },
      })
      const payload = await res.json().catch(() => ({}))
      if (res.ok() && payload && payload.ok === true) {
        stoppedOk = true
        break
      }
      await page.waitForTimeout(500)
    }
    expect(stoppedOk).toBe(true)

    // Converge the UI deterministically via refresh turbo-stream.
    await page.evaluate(async ({ conversationId, nodeId }) => {
      const url = `/conversations/${encodeURIComponent(conversationId)}/messages/refresh?node_id=${encodeURIComponent(nodeId)}`
      const res = await fetch(url, {
        method: "GET",
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin",
      })
      if (!res.ok) throw new Error(`refresh failed: ${res.status}`)
      const html = await res.text()
      window.Turbo?.renderStreamMessage?.(html)
    }, { conversationId, nodeId: nodeIdToStop })

    // Terminal stopped should hide the spinner in the active bubble.
    await expect(agentWrapper.locator('[data-role="spinner"]')).toBeHidden({ timeout: 60_000 })

    // After stopping, user can send a new message and get markdown without reload.
    await page.getByPlaceholder("Message…").fill("!md after stop")
    await page.getByRole("button", { name: "Send" }).click()
    await expect(page.getByText("!md after stop")).toBeVisible({ timeout: 10_000 })

    const finalAgentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(finalAgentWrapper).toBeVisible()

    const finalMessageId = await finalAgentWrapper.getAttribute("id")
    expect(finalMessageId).toBeTruthy()
    if (!finalMessageId) throw new Error("missing message wrapper id")

    const nodeId = finalMessageId.replace(/^message_/, "")

    const serverDeadline = Date.now() + 90_000
    let serverHasMarkdown = false
    while (Date.now() < serverDeadline) {
      const res = await page.request.get(page.url())
      const html = await res.text()
      if (html.includes("Mock Markdown")) {
        serverHasMarkdown = true
        break
      }
      await page.waitForTimeout(1000)
    }
    expect(serverHasMarkdown).toBe(true)

    await page.evaluate(async ({ conversationId, nodeId }) => {
      const url = `/conversations/${encodeURIComponent(conversationId)}/messages/refresh?node_id=${encodeURIComponent(nodeId)}`
      const res = await fetch(url, {
        method: "GET",
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin",
      })
      if (!res.ok) throw new Error(`refresh failed: ${res.status}`)
      const html = await res.text()
      if (!html.includes("turbo-stream")) throw new Error("expected turbo-stream response")
      window.Turbo?.renderStreamMessage?.(html)
    }, { conversationId, nodeId })

    const finalWrapper = page.locator(`#${finalMessageId}`)
    await expect(finalWrapper.locator('[data-controller="markdown"]')).toHaveCount(1, { timeout: 10_000 })
    await expect(finalWrapper.getByText("Mock Markdown", { exact: true })).toBeVisible()
  })
})
