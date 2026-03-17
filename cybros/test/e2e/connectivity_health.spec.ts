import { test, expect } from "@playwright/test"
import { signIn, createHighPriorityMockProvider, openNewConversation } from "./helpers"

test.describe("Connectivity health banner", () => {
  test("shows banner and pings /up when disconnected", async ({ page }) => {
    await signIn(page)
    await createHighPriorityMockProvider(page)

    await page.route("**/up", async (route) => {
      await route.fulfill({ status: 200, contentType: "text/plain", body: "ok" })
    })

    await openNewConversation(page, `E2E Connectivity ${Date.now()}`)

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

    await page.waitForFunction(() => {
      const el = document.querySelector("[data-conversation-channel-conversation-id-value]")
      const app = window.Stimulus
      const controller = app?.getControllerForElementAndIdentifier?.(el, "connectivity-health")
      return controller?.everConnected === true
    })
    await expect(alert).toHaveClass(/hidden/)

    await page.evaluate(() => {
      const el = document.querySelector("[data-conversation-channel-conversation-id-value]")
      el?.setAttribute("data-conversation-channel-connected", "false")
    })

    await expect(alert).toBeVisible()
    await expect(alert).toContainText("Realtime disconnected. Trying to reconnect…")
    await expect(alert).toContainText("(server reachable)")
  })

  test("changing permission mode does not surface a false reconnect banner", async ({ page }) => {
    await signIn(page)
    await createHighPriorityMockProvider(page)
    await openNewConversation(page, `E2E Permission Connectivity ${Date.now()}`)

    const alert = page.locator('[data-connectivity-health-target="disconnectedAlert"]')
    const permissionPicker = page.getByTestId("conversation-composer-permission-picker")

    await expect(alert).toBeHidden()
    await permissionPicker.selectOption({ label: "Full access" })

    await expect(permissionPicker).toHaveValue("full_access")
    await expect(alert).toBeHidden()

    await page.waitForTimeout(1500)
    await expect(alert).toBeHidden()
  })
})
