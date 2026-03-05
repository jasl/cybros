import { test, expect } from "@playwright/test"
import { signIn } from "./helpers"

test.describe("Top-level pages smoke", () => {
  test("landing page renders when unauthenticated", async ({ page }) => {
    await page.goto("/")
    await expect(page.getByRole("link", { name: "Sign in" })).toBeVisible()
  })

  test("authenticated pages render", async ({ page }) => {
    await signIn(page)

    await page.goto("/dashboard")
    await expect(page.getByTestId("dashboard-page")).toBeVisible()

    await page.goto("/conversations")
    await expect(page.getByRole("heading", { name: "Conversations" })).toBeVisible()

    await page.goto("/agent_programs")
    await expect(page.getByRole("heading", { name: "Agents" })).toBeVisible()

    await page.goto("/settings/profile")
    await expect(page.getByRole("heading", { name: "Profile" })).toBeVisible()

    await page.goto("/system/settings/llm_providers")
    await expect(page.getByRole("heading", { name: "LLM Providers" })).toBeVisible()
  })
})

