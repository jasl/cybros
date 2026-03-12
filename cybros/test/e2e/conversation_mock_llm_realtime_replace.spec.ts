import { test, expect } from "@playwright/test"
import { signIn, openConversationWithMockRuntime } from "./helpers"

test.describe("Conversation dual-channel (ActionCable ephemeral + Turbo truth)", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("Turbo replace renders final markdown in-place (no reload)", async ({ page }) => {
    test.setTimeout(150_000)

    await openConversationWithMockRuntime(page, `E2E Realtime ${Date.now()}`)

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
    const finalBubble = finalWrapper.locator('[data-role="agent-bubble"]')
    await expect(finalBubble).toHaveAttribute("data-node-state", "finished", { timeout: 90_000 })
    await expect(finalBubble.locator('[data-controller="markdown"]')).toHaveCount(1, { timeout: 90_000 })
    await expect(finalWrapper.getByText("Mock Markdown", { exact: true })).toBeVisible()

    // Sanity: we did not need a refresh/navigation to reach markdown.
    await expect(page).toHaveURL(/\/conversations\//)
  })
})
