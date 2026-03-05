import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider } from "./helpers"

test.describe("Conversation reconnect/resume (no duplication)", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
    await createHighPriorityMockProvider(page)
  })

  test("reload mid-stream resumes without duplicating already-received text", async ({ page }) => {
    test.setTimeout(180_000)

    await page.goto("/conversations")
    await page.locator("main").getByPlaceholder("New conversation title").fill(`E2E Reconnect ${Date.now()}`)
    await page.locator("main").getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    const token = `reconnect-token-${Date.now()}`
    const longPrompt = "x".repeat(1200)
    const content = `!mock slow=0.03 -- ${token} ${longPrompt}`

    await page.getByPlaceholder("Message…").fill(content)
    await page.getByRole("button", { name: "Send" }).click()
    await expect(page.getByText(content)).toBeVisible({ timeout: 10_000 })

    const agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper).toBeVisible()

    const messageId = await agentWrapper.getAttribute("id")
    expect(messageId).toBeTruthy()
    if (!messageId) throw new Error("missing message wrapper id")

    const nodeId = messageId.replace(/^message_/, "")
    const textEl = page.locator(`#message_${nodeId} [data-role="text"]`)

    // Wait until we have received enough content to include the unique token (ensures we are mid-stream).
    await expect(textEl).toContainText(token, { timeout: 60_000 })

    // Reload mid-stream: subscription should resume from cursor without duplicating already-applied deltas.
    await page.reload()

    const textAfterReload = page.locator(`#message_${nodeId} [data-role="text"]`)
    await expect(textAfterReload).toContainText(token, { timeout: 60_000 })

    // Give it a moment to receive more streaming deltas after reconnect.
    await page.waitForTimeout(1000)

    const fullText = await textAfterReload.textContent()
    const haystack = String(fullText || "")

    const first = haystack.indexOf(token)
    expect(first).toBeGreaterThanOrEqual(0)
    const second = haystack.indexOf(token, first + token.length)
    expect(second).toBe(-1)
  })
})

