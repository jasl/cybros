import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider } from "./helpers"

test.describe("Conversation rapid sends ordering", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
    await createHighPriorityMockProvider(page)
  })

  test("rapid sends preserve DOM ordering of user messages", async ({ page }) => {
    test.setTimeout(150_000)

    await page.goto("/conversations")
    await page.locator("main").getByPlaceholder("New conversation title").fill(`E2E Rapid Sends ${Date.now()}`)
    await page.locator("main").getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    const messages = [`rapid-1-${Date.now()}`, `rapid-2-${Date.now()}`, `rapid-3-${Date.now()}`]

    for (const msg of messages) {
      await page.getByPlaceholder("Message…").fill(msg)
      await page.getByRole("button", { name: "Send" }).click()
      await expect(page.getByText(msg)).toBeVisible({ timeout: 10_000 })
    }

    const indices = await page.evaluate((msgs) => {
      const list = document.querySelector("[id^='messages_list_conversation_']")
      if (!list) throw new Error("missing messages_list")

      const children = Array.from(list.children).filter((el) => el instanceof HTMLElement)
      const childIds = children.map((el) => String((el).id || ""))

      const wrapperIndexByUserText = (text) => {
        const match = children.find((el) => {
          const p = el.querySelector("p.whitespace-pre-wrap")
          return p && p.textContent === text
        })
        if (!match) return -1
        const id = String((match).id || "")
        return childIds.indexOf(id)
      }

      return msgs.map((m) => wrapperIndexByUserText(m))
    }, messages)

    expect(indices.length).toBe(3)
    expect(indices[0]).toBeGreaterThanOrEqual(0)
    expect(indices[1]).toBeGreaterThan(indices[0])
    expect(indices[2]).toBeGreaterThan(indices[1])
  })
})

