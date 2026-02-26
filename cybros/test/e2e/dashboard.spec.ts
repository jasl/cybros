import { test, expect } from "@playwright/test"
import { signIn } from "./helpers"

test.describe("Dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("renders dashboard page", async ({ page }) => {
    await expect(page.getByTestId("dashboard-page")).toBeVisible()
  })

  test("shows stats cards", async ({ page }) => {
    await expect(page.getByText("LLM providers")).toBeVisible()
    await expect(page.getByText("Agent programs")).toBeVisible()
    await expect(page.getByText("Runs")).toBeVisible()
  })

  test("shows recent conversations section", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Recent conversations" })).toBeVisible()
  })

  test("shows last run section", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Last run" })).toBeVisible()
  })

  test("'New chat' button creates a conversation", async ({ page }) => {
    await page.getByRole("button", { name: "New chat" }).click()

    await expect(page).toHaveURL(/\/conversations\//)
  })

  test("'Agents' link navigates to agent programs", async ({ page }) => {
    await page.getByRole("link", { name: "Agents" }).click()

    await expect(page).toHaveURL(/\/agent_programs/)
  })
})
