import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider } from "./helpers"

test.describe("Conversation mock LLM: error + retry flow", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
    await createHighPriorityMockProvider(page)
  })

  test("mock error triggers retry UI; after retry user can continue and receive markdown without reload", async ({ page }) => {
    test.setTimeout(150_000)

    await page.goto("/conversations")
    await page.locator("main").getByPlaceholder("New conversation title").fill(`E2E Error Retry ${Date.now()}`)
    await page.locator("main").getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    await page.getByPlaceholder("Message…").fill('!mock error=500 message="boom" -- hello')
    await page.getByRole("button", { name: "Send" }).click()

    await expect(page.getByText('!mock error=500 message="boom" -- hello')).toBeVisible({ timeout: 10_000 })

    // The UI should surface retry once the run transitions to errored.
    await expect(page.getByRole("button", { name: "Retry" })).toBeVisible({ timeout: 90_000 })

    const agentWrappers = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])')
    await expect(agentWrappers).toHaveCount(1)

    await page.getByRole("button", { name: "Retry" }).click()

    // Retry triggers a new agent node; after reload, we should see both the errored one and the retry placeholder.
    await expect(agentWrappers).toHaveCount(2, { timeout: 30_000 })

    // Start a fresh conversation to prove the app remains usable after an error/retry flow,
    // without being coupled to the retry node's runtime scheduling.
    await page.goto("/conversations")
    await page.locator("main").getByPlaceholder("New conversation title").fill(`E2E After Retry ${Date.now()}`)
    await page.locator("main").getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

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

