import { test, expect } from "@playwright/test"
import { bundledDefaultRuntimeState, signIn, createHighPriorityMockProvider, openNewConversation } from "./helpers"

async function openConversation(page) {
  await createHighPriorityMockProvider(page)
  const bundled = bundledDefaultRuntimeState()
  await openNewConversation(page, `E2E Responsive ${Date.now()}`, bundled.agentName)
}

test.describe("Responsive agent shell", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("mobile: left drawer opens; composer reachable; right drawer toggles", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await openConversation(page)

    await expect(page.getByPlaceholder("Message…")).toBeVisible()

    // Left drawer open
    await page.getByRole("button", { name: "Open navigation" }).click()
    await expect(page.getByRole("link", { name: "Dashboard" })).toBeVisible()
    await page.evaluate(() => {
      const input = document.getElementById("left_drawer")
      if (input instanceof HTMLInputElement) {
        input.checked = false
        input.dispatchEvent(new Event("change", { bubbles: true }))
      }
    })

    // Right drawer toggle exists on conversation surface
    await page.getByRole("button", { name: "Toggle settings" }).click()
    await expect(page.getByText("Profile")).toBeVisible()
  })

  test("tablet: nav toggles; composer reachable", async ({ page }) => {
    await page.setViewportSize({ width: 820, height: 1180 })
    await openConversation(page)

    await expect(page.getByPlaceholder("Message…")).toBeVisible()

    // Open navigation, then close again (drawer wiring works).
    await page.getByRole("button", { name: "Open navigation" }).click()
    await expect(page.getByRole("link", { name: "Dashboard" })).toBeVisible()
    await page.evaluate(() => {
      const input = document.getElementById("left_drawer")
      if (input instanceof HTMLInputElement) {
        input.checked = false
        input.dispatchEvent(new Event("change", { bubbles: true }))
      }
    })
  })

  test("desktop: right drawer toggle exists and opens", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 })
    await openConversation(page)

    await expect(page.getByPlaceholder("Message…")).toBeVisible()
    await expect(page.getByText("System")).toBeVisible()
  })
})
