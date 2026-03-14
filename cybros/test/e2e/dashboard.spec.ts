import { test, expect } from "@playwright/test"
import { bundledDefaultRuntimeState, createHighPriorityMockProvider, signIn } from "./helpers"

test.describe("Dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("renders dashboard page", async ({ page }) => {
    await expect(page.getByTestId("dashboard-page")).toBeVisible()
  })

  test("shows stats cards", async ({ page }) => {
    await expect(page.locator(".stat-title").filter({ hasText: "LLM providers" })).toBeVisible()
    await expect(page.locator(".stat-title").filter({ hasText: "Available agents" })).toBeVisible()
    await expect(page.locator(".stat-title").filter({ hasText: "Runs" })).toBeVisible()
  })

  test("shows recent conversations section", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Recent conversations" })).toBeVisible()
  })

  test("shows last run section", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Last run" })).toBeVisible()
  })

  test("agent launcher creates a conversation and generic new chat is absent", async ({ page }) => {
    await createHighPriorityMockProvider(page)
    const bundled = bundledDefaultRuntimeState()
    await page.goto("/dashboard")
    const defaultAgent = page.getByTestId("dashboard-agent-row").filter({ has: page.getByText(bundled.agentName, { exact: true }) }).first()

    await expect(defaultAgent).toBeVisible()
    await expect(page.getByRole("button", { name: "New chat" })).toHaveCount(0)
    await defaultAgent.getByRole("button", { name: "New conversation" }).click()

    await expect(page).toHaveURL(/\/conversations\//)
  })
})
