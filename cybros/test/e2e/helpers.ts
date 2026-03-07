import { type Page, expect } from "@playwright/test"

export async function signIn(page: Page, email = "admin@example.com", password = "Passw0rd") {
  await page.goto("/session/new")

  // Fresh dev DB redirects to setup wizard.
  const setupHeading = page.getByRole("heading", { name: "Set up Cybros" })
  if (await setupHeading.isVisible().catch(() => false)) {
    await page.getByLabel("Email").fill(email)
    await page.getByLabel("Password", { exact: true }).fill(password)
    await page.getByLabel("Confirm password").fill(password)
    await page.getByRole("button", { name: "Create account" }).click()
    await page.waitForURL("**/dashboard")
    return
  }

  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await page.waitForURL("**/dashboard")
}

export async function createHighPriorityMockProvider(page: Page) {
  await page.goto("/system/settings/llm_providers")
  await page.locator('select[name="default_model_ref"]').selectOption("dev/mock-model")
  await page.getByRole("button", { name: "Save default" }).click()
  await expect(page.getByText("Site override: dev/mock-model")).toBeVisible()
}
