import { test, expect } from "@playwright/test"
import { signIn, openConversationWithMockRuntime } from "./helpers"

async function waitForVisibleStopButton(page) {
  const stopButton = page.getByRole("button", { name: "Stop" })
  await expect(stopButton).toBeVisible({ timeout: 60_000 })
  return stopButton
}

test.describe("Conversation mock LLM: stop flow", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("slow streaming run can be stopped; conversation remains usable", async ({ page }) => {
    test.setTimeout(180_000)

    await openConversationWithMockRuntime(page, `E2E Stop ${Date.now()}`)

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

    const stopButton = await waitForVisibleStopButton(page)
    await stopButton.click()
    const stoppedBubble = agentWrapper.locator('[data-role="agent-bubble"]')
    await expect(stoppedBubble).toHaveAttribute("data-node-state", "stopped", { timeout: 60_000 })
    await expect(stoppedBubble.locator('[data-role="spinner"]')).toBeHidden({ timeout: 60_000 })

    // After stopping, user can send a new message and get markdown without reload.
    await page.getByPlaceholder("Message…").fill("!md after stop")
    await page.getByRole("button", { name: "Send" }).click()
    await expect(page.getByText("!md after stop")).toBeVisible({ timeout: 10_000 })

    const finalAgentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(finalAgentWrapper).toBeVisible()

    const finalMessageId = await finalAgentWrapper.getAttribute("id")
    expect(finalMessageId).toBeTruthy()
    if (!finalMessageId) throw new Error("missing message wrapper id")

    const finalWrapper = page.locator(`#${finalMessageId}`)
    const finalBubble = finalWrapper.locator('[data-role="agent-bubble"]')
    await expect(finalBubble).toHaveAttribute("data-node-state", "finished", { timeout: 90_000 })
    await expect(finalBubble.locator('[data-controller="markdown"]')).toHaveCount(1, { timeout: 90_000 })
    await expect(finalWrapper.getByText("Mock Markdown", { exact: true })).toBeVisible()
  })
})
