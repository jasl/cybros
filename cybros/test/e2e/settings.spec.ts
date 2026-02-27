import { test, expect } from "@playwright/test"
import { signIn } from "./helpers"

test.describe("Settings", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("profile page renders with email", async ({ page }) => {
    await page.goto("/settings/profile")

    await expect(page.getByRole("heading", { name: "Profile" })).toBeVisible()
    await expect(page.locator("main").getByText("admin@example.com")).toBeVisible()
  })

  test("profile page shows email and password sections", async ({ page }) => {
    await page.goto("/settings/profile")

    await expect(page.getByRole("heading", { name: "Email" })).toBeVisible()
    await expect(page.getByRole("heading", { name: "Password" })).toBeVisible()
  })

  test("sessions page renders with active sessions", async ({ page }) => {
    await page.goto("/settings/sessions")

    await expect(page.getByRole("heading", { name: "Sessions" })).toBeVisible()
    await expect(page.getByText("Signed in as")).toBeVisible()
    await expect(page.getByRole("button", { name: "Sign out all" })).toBeVisible()
  })

  test("sessions page shows session table", async ({ page }) => {
    await page.goto("/settings/sessions")

    await expect(page.getByRole("table")).toBeVisible()
    await expect(page.getByText("This device")).toBeVisible()
  })
})

test.describe("System Settings", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("LLM providers page renders", async ({ page }) => {
    await page.goto("/system/settings/llm_providers")

    await expect(page.getByRole("heading", { name: "LLM Providers" })).toBeVisible()
    await expect(page.getByRole("link", { name: "New provider" })).toBeVisible()
  })

  test("LLM providers page shows table", async ({ page }) => {
    await page.goto("/system/settings/llm_providers")

    await expect(page.getByRole("table")).toBeVisible()
  })

  test("agent programs page renders", async ({ page }) => {
    await page.goto("/system/settings/agent_programs")

    await expect(page.getByRole("heading", { name: "Agent Programs" })).toBeVisible()
    await expect(page.getByRole("link", { name: "New agent" })).toBeVisible()
  })

  test("agent programs page shows table and search", async ({ page }) => {
    await page.goto("/system/settings/agent_programs")

    await expect(page.getByRole("table")).toBeVisible()
    await expect(page.getByPlaceholder("Search name or profile")).toBeVisible()
  })
})
