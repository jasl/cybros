import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider } from "./helpers"

test.describe("Conversation with Mock LLM streaming + markdown", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("send creates placeholder; final markdown is durable after reload", async ({ page }) => {
    await createHighPriorityMockProvider(page)

    // Create a new conversation and send a message that asks the mock to return markdown.
    await page.goto("/conversations")
    await page.locator("main").getByPlaceholder("New conversation title").fill(`E2E Mock LLM ${Date.now()}`)
    await page.locator("main").getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    await page.getByPlaceholder("Message…").fill("!md please respond with markdown")
    await page.getByRole("button", { name: "Send" }).click()

    await expect(page.getByText("!md please respond with markdown")).toBeVisible({ timeout: 10_000 })

    // Placeholder exists immediately (HTTP Turbo Streams truth).
    await expect(page.locator('[data-role="agent-bubble"]').first()).toBeVisible()

    // Durability contract: final message must be reconstructable after refresh.
    // (Realtime delivery is covered by `conversation_mock_llm_realtime_replace.spec.ts`.)
    const deadline = Date.now() + 30_000
    while (Date.now() < deadline) {
      const count = await page.locator('[data-role="agent-bubble"] [data-controller="markdown"]').count()
      if (count > 0) break
      await page.waitForTimeout(750)
      await page.reload()
    }

    const markdownRoot = page.locator('[data-role="agent-bubble"] [data-controller="markdown"]').first()
    await expect(markdownRoot).toHaveCount(1)
    await expect(page.getByText("Mock Markdown")).toBeVisible()
  })
})
