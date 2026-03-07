import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider } from "./helpers"

test.describe("Connectivity health banner", () => {
  test("shows banner and pings /up when disconnected", async ({ page }) => {
    await signIn(page)
    await createHighPriorityMockProvider(page)

    await page.route("**/up", async (route) => {
      await route.fulfill({ status: 200, contentType: "text/plain", body: "ok" })
    })

    await page.goto("/conversations")
    await page.getByPlaceholder("New conversation title").fill(`E2E Connectivity ${Date.now()}`)
    await page.locator("main").getByRole("button", { name: "New", exact: true }).click()
    await expect(page).toHaveURL(/\/conversations\//)

    const alert = page.locator('[data-connectivity-health-target="disconnectedAlert"]')

    // Detach the real conversation-channel controller so it doesn't race our attribute toggles.
    await page.evaluate(() => {
      const el = document.querySelector("[data-conversation-channel-conversation-id-value]")
      const app = window.Stimulus
      try {
        const controller = app?.getControllerForElementAndIdentifier?.(el, "conversation-channel")
        controller?.disconnect?.()
      } catch (_e) {}
    })

    // Simulate a successful connect, then a disconnect.
    await page.evaluate(() => {
      const el = document.querySelector("[data-conversation-channel-conversation-id-value]")
      el?.setAttribute("data-conversation-channel-connected", "true")
    })
    await expect(alert).toHaveClass(/hidden/)

    await page.evaluate(() => {
      const el = document.querySelector("[data-conversation-channel-conversation-id-value]")
      el?.setAttribute("data-conversation-channel-connected", "false")
    })

    await expect(page.getByText("Realtime disconnected. Trying to reconnect…")).toBeVisible()
    await expect(page.getByText("(server reachable)")).toBeVisible()
  })
})
