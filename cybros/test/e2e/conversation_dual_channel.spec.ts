import { test, expect } from "@playwright/test"
import { openNewConversation, signIn } from "./helpers"

test.describe("Conversation dual-channel skeleton", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("show page has Turbo stream subscription and renders agent placeholder on send", async ({ page }) => {
    await openNewConversation(page, `E2E Dual Channel ${Date.now()}`)

    await expect(page.locator('turbo-cable-stream-source[channel="Turbo::StreamsChannel"]')).toHaveCount(1)

    await page.getByPlaceholder("Message…").fill("hello")
    await page.getByRole("button", { name: "Send" }).click()

    await expect(page.getByText("hello")).toBeVisible({ timeout: 10_000 })

    // Empty state should be hidden or removed after first send.
    const emptyState = page.locator('[id^="messages_empty_state_conversation_"]')
    await expect(emptyState).toHaveCount(0)

    // Agent placeholder bubble exists (pending/running/streaming).
    await expect(page.locator('[data-role="agent-bubble"]').first()).toBeVisible()
  })
})
