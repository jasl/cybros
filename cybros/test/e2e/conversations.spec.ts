import { test, expect } from "@playwright/test"
import { signIn } from "./helpers"

test.describe("Conversations", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("index page renders with conversation list", async ({ page }) => {
    await page.goto("/conversations")

    await expect(page.getByRole("heading", { name: "Conversations" })).toBeVisible()
    await expect(page.getByRole("table")).toBeVisible()
  })

  test("pagination via 'Older' link works", async ({ page }) => {
    await page.goto("/conversations")

    const olderLink = page.getByRole("link", { name: "Older" })
    if (await olderLink.isVisible()) {
      await olderLink.click()
      await expect(page).toHaveURL(/before=/)
      await expect(page.getByRole("link", { name: "Back to latest" })).toBeVisible()
    }
  })

  test("creating a new conversation from index", async ({ page }) => {
    await page.goto("/conversations")

    await page.getByPlaceholder("New conversation title").fill("E2E Test Conversation")
    await page.getByRole("button", { name: "New" }).click()

    await expect(page).toHaveURL(/\/conversations\//)
  })

  test("conversation show page renders chat interface", async ({ page }) => {
    await page.goto("/conversations")

    await page.getByPlaceholder("New conversation title").fill("E2E Chat Test")
    await page.getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    await expect(page.getByPlaceholder("Message…")).toBeVisible()
    await expect(page.getByRole("button", { name: "Send" })).toBeVisible()
  })

  test("send a message and verify it appears", async ({ page }) => {
    await page.goto("/conversations")

    await page.getByPlaceholder("New conversation title").fill("E2E Message Test")
    await page.getByRole("button", { name: "New" }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    await page.getByPlaceholder("Message…").fill("Hello from Playwright E2E test")
    await page.getByRole("button", { name: "Send" }).click()

    await expect(page.getByText("Hello from Playwright E2E test")).toBeVisible({ timeout: 10_000 })
  })

  test("accessing a non-existent conversation returns 404", async ({ page }) => {
    const response = await page.goto("/conversations/00000000-0000-0000-0000-000000000000")

    expect(response?.status()).toBe(404)
  })
})
