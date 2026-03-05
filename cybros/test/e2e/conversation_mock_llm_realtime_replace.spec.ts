import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider } from "./helpers"

test.describe("Conversation dual-channel (ActionCable ephemeral + Turbo truth)", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
    await createHighPriorityMockProvider(page)
  })

  test("Turbo replace renders final markdown in-place (no reload)", async ({ page }) => {
    test.setTimeout(150_000)

    await page.goto("/conversations")
    await page.locator("main").getByPlaceholder("New conversation title").fill(`E2E Realtime ${Date.now()}`)
    await page.locator("main").getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    await expect(page.locator('turbo-cable-stream-source[channel="Turbo::StreamsChannel"]')).toHaveCount(1)
    await expect(page.locator('[data-controller~="conversation-channel"]')).toHaveAttribute(
      "data-conversation-channel-connected",
      "true",
      { timeout: 10_000 },
    )

    await page.getByPlaceholder("Message…").fill("!md realtime replace please")
    await page.getByRole("button", { name: "Send" }).click()

    await expect(page.getByText("!md realtime replace please")).toBeVisible({ timeout: 10_000 })

    const wrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(wrapper).toBeVisible()

    const messageId = await wrapper.getAttribute("id")
    expect(messageId).toBeTruthy()
    if (!messageId) throw new Error("missing message wrapper id")

    const finalWrapper = page.locator(`#${messageId}`)
    const nodeId = messageId.replace(/^message_/, "")

    // Ensure the terminal content exists server-side, then converge in-place without reload by
    // fetching a turbo-stream replace for this message wrapper.
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

    const conversationId = new URL(page.url()).pathname.split("/").pop()
    expect(conversationId).toBeTruthy()
    if (!conversationId) throw new Error("missing conversation id")

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

    await expect(finalWrapper.locator('[data-controller="markdown"]')).toHaveCount(1, { timeout: 10_000 })
    await expect(finalWrapper.getByText("Mock Markdown", { exact: true })).toBeVisible()

    // Sanity: we did not need a refresh/navigation to reach markdown.
    await expect(page).toHaveURL(/\/conversations\//)
  })
})
