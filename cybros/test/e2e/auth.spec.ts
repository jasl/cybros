import { test, expect } from "@playwright/test"
import { signIn } from "./helpers"

test.describe("Authentication", () => {
  test("login page renders with sign-in form", async ({ page }) => {
    await page.goto("/session/new")

    await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible()
    await expect(page.getByLabel("Email")).toBeVisible()
    await expect(page.getByLabel("Password")).toBeVisible()
    await expect(page.getByRole("button", { name: "Sign in" })).toBeVisible()
  })

  test("successful sign in redirects to dashboard", async ({ page }) => {
    await signIn(page)

    await expect(page).toHaveURL(/\/dashboard/)
    await expect(page.getByTestId("dashboard-page")).toBeVisible()
  })

  test("invalid credentials show error", async ({ page }) => {
    await page.goto("/session/new")
    await page.getByLabel("Email").fill("admin@example.com")
    await page.getByLabel("Password").fill("wrong-password")
    await page.getByRole("button", { name: "Sign in" }).click()

    await expect(page.locator("#toast_container")).toContainText("Invalid email or password")
  })

  test("sign out returns to home page", async ({ page }) => {
    await signIn(page)

    await page.locator(".dropdown [role=\"button\"]").first().click()
    await page.getByText("Sign out", { exact: true }).click()

    await expect(page).toHaveURL(/\/session\/new/)
  })

  test("unauthenticated user is redirected to sign in", async ({ page }) => {
    await page.goto("/dashboard")

    await expect(page).toHaveURL(/\/session\/new/)
  })
})
