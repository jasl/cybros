import { type Page, expect } from "@playwright/test"

export async function signIn(page: Page, email = "admin@example.com", password = "Passw0rd") {
  await page.goto("/session/new")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password").fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await page.waitForURL("**/dashboard")
}
