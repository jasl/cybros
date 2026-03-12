import { test, expect } from "@playwright/test"
import { signIn, openConversationWithMockRuntime, openHotkeysFixtureConversation } from "./helpers"

async function addHiddenComposerInput(page, { name, value }) {
  await page.locator('form[data-controller~="message-form"]').evaluate(
    (form, { inputName, inputValue }) => {
      let input = form.querySelector(`input[name="${inputName}"]`)
      if (!(input instanceof HTMLInputElement)) {
        input = document.createElement("input")
        input.type = "hidden"
        input.name = inputName
        form.appendChild(input)
      }

      input.disabled = false
      input.value = inputValue
    },
    { inputName: name, inputValue: String(value) },
  )
}

async function createConversationAndWaitForMarkdown(page) {
  await openConversationWithMockRuntime(page, `E2E Actions ${Date.now()}`)

  await page.getByPlaceholder("Message…").fill("!md please respond with markdown")
  await page.getByRole("button", { name: "Send" }).click()

  await expect(page.getByText("!md please respond with markdown")).toBeVisible({ timeout: 10_000 })
  await waitForTailAgentToFinishWithMarkdown(page)
  await expect(page.locator('[data-role="agent-bubble"]').last().locator('[data-controller="markdown"]')).toHaveCount(1)
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

async function waitForTailAgentToEnterInFlightState(page) {
  const deadline = Date.now() + 60_000
  while (Date.now() < deadline) {
    const tailBubble = page.locator('[data-role="agent-bubble"]').last()
    const state = (await tailBubble.getAttribute("data-node-state").catch(() => "")) || ""
    if (state === "pending" || state === "running") {
      await expect(page.getByRole("button", { name: "Stop" })).toBeVisible({ timeout: 20_000 })
      return
    }

    await page.waitForTimeout(750)
    await page.reload()
  }

  await expect(page.locator('[data-role="agent-bubble"]').last()).toHaveAttribute("data-node-state", /pending|running/)
}

test.describe("Conversation message actions + hotkeys", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("a follow-up sent while the current run is active eventually lands in the transcript", async ({ page }) => {
    test.setTimeout(150_000)
    await openConversationWithMockRuntime(page, `E2E Composer ${Date.now()}`)

    const longPrompt = "please continue slowly and keep streaming ".repeat(80)
    await page.getByPlaceholder("Message…").fill(`!mock slow=0.03 -- ${longPrompt}`)
    await addHiddenComposerInput(page, {
      name: "input_policy_override[input_coalescing][window_ms]",
      value: 0,
    })
    await page.getByRole("button", { name: "Send" }).click()

    await waitForTailAgentToEnterInFlightState(page)

    const queuedFollowUp = "queued follow up from e2e"
    await page.getByPlaceholder("Message…").fill(queuedFollowUp)
    await page.getByRole("button", { name: "Send" }).click()

    const messageList = page.locator("[id^='messages_list_conversation_']")
    await expect(messageList).toContainText(queuedFollowUp, { timeout: 90_000 })
  })

  test("copy copies the agent message markdown; branch navigates to a branch conversation", async ({ page }) => {
    await createConversationAndWaitForMarkdown(page)

    const agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper).toBeVisible()

    await page.evaluate(() => {
      const e2eWindow = window as Window & { __copiedText?: string | null }
      e2eWindow.__copiedText = null
      const clipboard = navigator.clipboard
      if (!clipboard || typeof clipboard.writeText !== "function") {
        throw new Error("clipboard.writeText unavailable")
      }

      clipboard.writeText = async (text) => {
        e2eWindow.__copiedText = String(text)
      }
    })

    await agentWrapper.getByRole("button", { name: "Copy" }).click()

    await expect
      .poll(async () => page.evaluate(() => (window as Window & { __copiedText?: string | null }).__copiedText || ""))
      .toContain("Mock Markdown")

    const beforeUrl = page.url()
    await agentWrapper.getByRole("button", { name: "Branch" }).click()
    await page.waitForURL((u) => u.toString() !== beforeUrl, { timeout: 30_000 })
  })

  test("hotkeys: Ctrl+Enter regenerates tail; ArrowLeft/Right swipes between versions", async ({ page }) => {
    test.setTimeout(150_000)
    await openHotkeysFixtureConversation(page, `E2E Hotkeys ${Date.now()}`)

    let agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper).toBeVisible()
    await expect(agentWrapper.locator('[data-controller="markdown"]')).toHaveCount(1)
    await expect(agentWrapper.locator('[data-message-actions-target="swipeCount"]')).toHaveText("1 / 1")

    const firstId = await agentWrapper.getAttribute("id")
    expect(firstId).toBeTruthy()
    if (!firstId) throw new Error("missing agent wrapper id")

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

    await page.keyboard.press("Control+Enter")
    await page.waitForLoadState("domcontentloaded")

    const fetchDeadline = Date.now() + 15_000
    while (Date.now() < fetchDeadline) {
      const saw = await page.evaluate(() => {
        return Array.isArray(window.__e2e_fetch_urls) && window.__e2e_fetch_urls.some((u) => String(u).includes("/regenerate"))
      })
      if (saw) break
      await page.waitForTimeout(100)
    }

    agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper.locator('[data-message-actions-target="swipeCount"]')).toHaveText("2 / 2", { timeout: 60_000 })

    await waitForTailAgentToFinishWithMarkdown(page)

    agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    const regeneratedId = await agentWrapper.getAttribute("id")
    expect(regeneratedId).toBeTruthy()
    if (!regeneratedId) throw new Error("missing regenerated agent wrapper id")
    expect(regeneratedId).not.toEqual(firstId)

    // ArrowLeft should adopt the previous version.
    await page.locator("main").click()
    await page.keyboard.press("ArrowLeft")
    await page.waitForLoadState("domcontentloaded")

    agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper.locator('[data-message-actions-target="swipeCount"]')).toHaveText("1 / 2", { timeout: 30_000 })
    const swipedLeftId = await agentWrapper.getAttribute("id")
    expect(swipedLeftId).toBeTruthy()
    if (!swipedLeftId) throw new Error("missing agent wrapper id after swipe left")
    expect(swipedLeftId).not.toEqual(regeneratedId)

    // ArrowRight should adopt the newer version again.
    await page.locator("main").click()
    await page.keyboard.press("ArrowRight")
    await page.waitForLoadState("domcontentloaded")

    agentWrapper = page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
    await expect(agentWrapper.locator('[data-message-actions-target="swipeCount"]')).toHaveText("2 / 2", { timeout: 30_000 })
    const swipedRightId = await agentWrapper.getAttribute("id")
    expect(swipedRightId).toEqual(regeneratedId)
  })

  test("?: opens hotkeys help modal", async ({ page }) => {
    await createConversationAndWaitForMarkdown(page)
    await page.locator("main").click()
    await page.keyboard.press("?")
    await expect(page.getByRole("heading", { name: "Keyboard Shortcuts" })).toBeVisible()
    await expect(page.getByText("Replay tail assistant message")).toBeVisible()
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
