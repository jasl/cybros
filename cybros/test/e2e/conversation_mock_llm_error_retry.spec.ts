import { test, expect } from "@playwright/test"
import { signIn, openConversationWithMockRuntime } from "./helpers"

test.describe("Conversation mock LLM: error recovery flow", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("mock error is surfaced in the transcript and the app remains usable without reload", async ({ page }) => {
    test.setTimeout(150_000)

    await openConversationWithMockRuntime(page, `E2E Error Retry ${Date.now()}`)

    await page.getByPlaceholder("Message…").fill('!mock error=500 message="boom" -- hello')
    await page.getByRole("button", { name: "Send" }).click()

    await expect(page.getByText('!mock error=500 message="boom" -- hello')).toBeVisible({ timeout: 10_000 })

    const errorWrapper = page.locator('div[id^="message_"]:has-text("Task notice: provider_error")')
    await expect(errorWrapper).toBeVisible({ timeout: 90_000 })
    await expect(errorWrapper.getByText("Reported error: boom")).toBeVisible()
    await expect(page.getByRole("button", { name: "Retry" })).toHaveCount(0)

    // Start a fresh conversation to prove the app remains usable after an error/retry flow,
    // without being coupled to the failed turn's runtime scheduling.
    await openConversationWithMockRuntime(page, `E2E After Retry ${Date.now()}`)

    await page.getByPlaceholder("Message…").fill("!md after retry")
    await page.getByRole("button", { name: "Send" }).click()
    await expect(page.getByText("!md after retry")).toBeVisible({ timeout: 10_000 })

    const finalAgentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(finalAgentWrapper).toBeVisible()

    const messageId = await finalAgentWrapper.getAttribute("id")
    expect(messageId).toBeTruthy()
    if (!messageId) throw new Error("missing message wrapper id")

    const nodeId = messageId.replace(/^message_/, "")
    const conversationId = new URL(page.url()).pathname.split("/").pop()
    expect(conversationId).toBeTruthy()
    if (!conversationId) throw new Error("missing conversation id")

    // Wait until the server has produced the terminal markdown for *this* node, then converge in-place.
    const serverDeadline = Date.now() + 90_000
    let serverHasMarkdown = false
    while (Date.now() < serverDeadline) {
      const res = await page.request.get(`/conversations/${conversationId}/messages/refresh?node_id=${nodeId}`, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
      })
      const html = await res.text()
      if (html.includes('data-controller="markdown"') && html.includes("Mock Markdown")) {
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

    const finalWrapper = page.locator(`#${messageId}`)
    await expect(finalWrapper.locator('[data-controller="markdown"]')).toHaveCount(1, { timeout: 10_000 })
    await expect(finalWrapper.getByText("Mock Markdown", { exact: true })).toBeVisible()
  })
})
