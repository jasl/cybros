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

async function waitForTailAgentToFinishWithMarkdown(page) {
  const deadline = Date.now() + 90_000
  while (Date.now() < deadline) {
    const tailBubble = page.locator('[data-role="agent-bubble"]').last()
    const state = (await tailBubble.getAttribute("data-node-state").catch(() => "")) || ""
    const hasMarkdown = (await tailBubble.locator('[data-controller="markdown"]').count().catch(() => 0)) > 0
    if (state === "finished" && hasMarkdown) return
    await page.waitForTimeout(750)
    await page.reload()
  }

  await expect(page.locator('[data-role="agent-bubble"]').last()).toHaveAttribute("data-node-state", "finished")
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

    // Ensure we don't trigger hotkeys while focus is in an input.
    await page.locator("main").click()

    // Ctrl+Enter regenerate (tail-only).
    await page.evaluate(() => {
      window.__e2e_fetch_urls = []
      const orig = window.fetch.bind(window)
      window.fetch = (...args) => {
        window.__e2e_fetch_urls.push(String(args[0] || ""))
        return orig(...args)
      }
    })

    await page.evaluate(() => {
      document.dispatchEvent(
        new KeyboardEvent("keydown", {
          key: "Enter",
          ctrlKey: true,
          bubbles: true,
          cancelable: true,
        }),
      )
    })
    await page.waitForLoadState("domcontentloaded")

    const fetchDeadline = Date.now() + 15_000
    while (Date.now() < fetchDeadline) {
      const saw = await page.evaluate(() => {
        return Array.isArray(window.__e2e_fetch_urls) && window.__e2e_fetch_urls.some((u) => String(u).includes("/regenerate"))
      })
      if (saw) break
      await page.waitForTimeout(100)
    }

    const regenDeadline = Date.now() + 60_000
    let secondId = null
    while (Date.now() < regenDeadline) {
      const afterRegen = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
      await expect(afterRegen).toBeVisible()
      secondId = await afterRegen.getAttribute("id")
      if (secondId && secondId !== firstId) break
      await page.waitForTimeout(750)
      await page.reload()
    }

    expect(secondId).toBeTruthy()
    if (!secondId) throw new Error("missing agent wrapper id after regenerate")
    const secondNodeId = secondId.replace(/^message_/, "")
    expect(secondNodeId).not.toEqual(firstNodeId)

    await waitForTailAgentToFinishWithMarkdown(page)

    // ArrowLeft should adopt the previous version.
    await page.locator("main").click()
    await page.keyboard.press("ArrowLeft")
    await page.waitForLoadState("domcontentloaded")

    const swipeLeftDeadline = Date.now() + 30_000
    let thirdId = null
    while (Date.now() < swipeLeftDeadline) {
      const afterSwipeLeft = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
      thirdId = await afterSwipeLeft.getAttribute("id")
      if (thirdId && thirdId !== secondId) break
      await page.waitForTimeout(500)
      await page.reload()
    }
    expect(thirdId).toBeTruthy()
    if (!thirdId) throw new Error("missing agent wrapper id after swipe")
    const thirdNodeId = thirdId.replace(/^message_/, "")
    expect(thirdNodeId).not.toEqual(secondNodeId)

    // ArrowRight should adopt the newer version again.
    await page.locator("main").click()
    await page.keyboard.press("ArrowRight")
    await page.waitForLoadState("domcontentloaded")

    const swipeRightDeadline = Date.now() + 30_000
    let fourthId = null
    while (Date.now() < swipeRightDeadline) {
      const afterSwipeRight = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
      fourthId = await afterSwipeRight.getAttribute("id")
      if (fourthId && fourthId === secondId) break
      await page.waitForTimeout(500)
      await page.reload()
    }
    expect(fourthId).toBeTruthy()
    if (!fourthId) throw new Error("missing agent wrapper id after swipe right")
    const fourthNodeId = fourthId.replace(/^message_/, "")
    expect(fourthNodeId).toEqual(secondNodeId)
  })

  test("?: opens hotkeys help modal", async ({ page }) => {
    await createConversationAndWaitForMarkdown(page)
    await page.locator("main").click()
    await page.keyboard.press("?")
    await expect(page.getByRole("heading", { name: "Keyboard Shortcuts" })).toBeVisible()
    await expect(page.getByText("Regenerate last assistant message")).toBeVisible()
  })

  test("? typed in composer does not open the help modal", async ({ page }) => {
    await createConversationAndWaitForMarkdown(page)

    const textarea = page.getByPlaceholder("Message…")
    await textarea.click()
    await textarea.type("?")

    await expect(page.getByRole("heading", { name: "Keyboard Shortcuts" })).toHaveCount(0)
    await expect(textarea).toHaveValue("?")
  })
})
