import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider } from "./helpers"

async function createConversationAndWaitForMarkdown(page) {
  await createHighPriorityMockProvider(page)

  await page.goto("/conversations")
  await page.locator("main").getByPlaceholder("New conversation title").fill(`E2E Actions ${Date.now()}`)
  await page.locator("main").getByRole("button", { name: "New" }).click()
  await expect(page).toHaveURL(/\/conversations\//)

  await page.getByPlaceholder("Message…").fill("!md please respond with markdown")
  await page.getByRole("button", { name: "Send" }).click()

  await expect(page.getByText("!md please respond with markdown")).toBeVisible({ timeout: 10_000 })

  const deadline = Date.now() + 60_000
  while (Date.now() < deadline) {
    const count = await page.locator('[data-role="agent-bubble"] [data-controller="markdown"]').count()
    if (count > 0) break
    await page.waitForTimeout(750)
    await page.reload()
  }

  await expect(page.locator('[data-role="agent-bubble"] [data-controller="markdown"]').first()).toHaveCount(1)
}

test.describe("Conversation message actions + hotkeys", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("copy copies the agent message markdown; branch navigates to a child conversation", async ({ page }) => {
    await page.context().grantPermissions(["clipboard-read", "clipboard-write"])
    await createConversationAndWaitForMarkdown(page)

    const agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper).toBeVisible()

    await agentWrapper.getByRole("button", { name: "Copy" }).click()

    const copied = await page.evaluate(async () => {
      return await navigator.clipboard.readText()
    })
    expect(copied).toContain("Mock Markdown")

    const beforeUrl = page.url()
    await agentWrapper.getByRole("button", { name: "Branch" }).click()
    await page.waitForURL((u) => u.toString() !== beforeUrl, { timeout: 30_000 })
  })

  test("hotkeys: Ctrl+Enter regenerates tail; ArrowLeft/Right swipes between versions", async ({ page }) => {
    test.setTimeout(150_000)
    await createConversationAndWaitForMarkdown(page)

    const agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper).toBeVisible()

    const firstId = await agentWrapper.getAttribute("id")
    expect(firstId).toBeTruthy()
    if (!firstId) throw new Error("missing agent wrapper id")
    const firstNodeId = firstId.replace(/^message_/, "")

    // Ctrl+Enter regenerate (tail-only).
    await page.keyboard.press("Control+Enter")
    await page.waitForTimeout(500)
    await page.waitForLoadState("domcontentloaded")

    const afterRegen = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(afterRegen).toBeVisible()
    const secondId = await afterRegen.getAttribute("id")
    expect(secondId).toBeTruthy()
    if (!secondId) throw new Error("missing agent wrapper id after regenerate")
    const secondNodeId = secondId.replace(/^message_/, "")
    expect(secondNodeId).not.toEqual(firstNodeId)

    // ArrowLeft should adopt the previous version (back to first node id).
    await page.keyboard.press("ArrowLeft")
    await page.waitForTimeout(500)
    await page.waitForLoadState("domcontentloaded")

    const afterSwipeLeft = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    const thirdId = await afterSwipeLeft.getAttribute("id")
    expect(thirdId).toBeTruthy()
    if (!thirdId) throw new Error("missing agent wrapper id after swipe")
    const thirdNodeId = thirdId.replace(/^message_/, "")
    expect(thirdNodeId).toEqual(firstNodeId)

    // ArrowRight should adopt the newer version again.
    await page.keyboard.press("ArrowRight")
    await page.waitForTimeout(500)
    await page.waitForLoadState("domcontentloaded")

    const afterSwipeRight = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    const fourthId = await afterSwipeRight.getAttribute("id")
    expect(fourthId).toBeTruthy()
    if (!fourthId) throw new Error("missing agent wrapper id after swipe right")
    const fourthNodeId = fourthId.replace(/^message_/, "")
    expect(fourthNodeId).toEqual(secondNodeId)
  })

  test("?: opens hotkeys help modal", async ({ page }) => {
    await createConversationAndWaitForMarkdown(page)
    await page.keyboard.press("?")
    await expect(page.getByRole("heading", { name: "Keyboard Shortcuts" })).toBeVisible()
    await expect(page.getByText("Regenerate last assistant message")).toBeVisible()
  })
})

