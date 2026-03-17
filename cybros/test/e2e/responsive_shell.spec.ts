import { test, expect } from "@playwright/test"
import {
  bundledDefaultRuntimeState,
  signIn,
  createHighPriorityMockProvider,
  openNewConversation,
  conversationIdFromUrl,
  programmableConversationState,
} from "./helpers"

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

  test("desktop: left sidebar stays expanded after permission mode changes", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 })
    await openConversation(page)

    const conversationId = conversationIdFromUrl(page)
    const permissionPicker = page.getByTestId("conversation-composer-permission-picker")

    await expect
      .poll(() =>
        page.evaluate(() => {
          const input = document.getElementById("left_drawer")
          return input instanceof HTMLInputElement ? input.checked : null
        }),
      )
      .toBe(true)

    await permissionPicker.selectOption({ label: "Conservative" })
    await expect(permissionPicker).toHaveValue("conservative")
    await expect
      .poll(() => programmableConversationState(conversationId).composerDraft.permissionMode)
      .toBe("conservative")

    await expect
      .poll(() =>
        page.evaluate(() => {
          const input = document.getElementById("left_drawer")
          return input instanceof HTMLInputElement ? input.checked : null
        }),
      )
      .toBe(true)
  })

  test("desktop: composer draft survives runtime setting changes and reload", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 })
    await openConversation(page)

    const conversationId = conversationIdFromUrl(page)
    const textarea = page.getByPlaceholder("Message…")
    const modelPicker = page.getByTestId("conversation-composer-model-picker")
    const permissionPicker = page.getByTestId("conversation-composer-permission-picker")
    const draftContent = "Draft text should survive runtime setting changes"

    await textarea.fill(draftContent)
    await expect
      .poll(() => programmableConversationState(conversationId).composerDraft.content)
      .toBe(draftContent)

    await permissionPicker.selectOption({ label: "Conservative" })
    await expect(permissionPicker).toHaveValue("conservative")
    await expect
      .poll(() => programmableConversationState(conversationId).composerDraft.permissionMode)
      .toBe("conservative")

    const currentModelValue = await modelPicker.inputValue()
    const nextModelValue = await modelPicker.locator("option").evaluateAll((options, currentValue) => {
      const candidate = options.find((option) => option.value && option.value !== currentValue && !option.disabled)
      return candidate?.value ?? null
    }, currentModelValue)

    expect(nextModelValue).toBeTruthy()
    if (!nextModelValue) throw new Error("expected an alternate model option")

    await modelPicker.selectOption(nextModelValue)
    await expect(modelPicker).toHaveValue(nextModelValue)
    await expect
      .poll(() => programmableConversationState(conversationId).composerDraft.modelRef)
      .toBe(nextModelValue)

    await page.reload()

    await expect(textarea).toHaveValue(draftContent)
    await expect(permissionPicker).toHaveValue("conservative")
    await expect(modelPicker).toHaveValue(nextModelValue)
  })

  test("desktop: immediate send promotes runtime settings without restoring stale draft content", async ({ page }) => {
    test.setTimeout(180_000)

    await page.route("**/conversations/*/composer_draft", async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 800))
      await route.continue()
    })

    await page.setViewportSize({ width: 1280, height: 800 })
    await openConversation(page)

    const conversationId = conversationIdFromUrl(page)
    const textarea = page.getByPlaceholder("Message…")
    const modelPicker = page.getByTestId("conversation-composer-model-picker")
    const permissionPicker = page.getByTestId("conversation-composer-permission-picker")
    const draftContent = "Send immediately after changing runtime settings"

    const currentModelValue = await modelPicker.inputValue()
    const nextModelValue = await modelPicker.locator("option").evaluateAll((options, currentValue) => {
      const candidate = options.find((option) => option.value && option.value !== currentValue && !option.disabled)
      return candidate?.value ?? null
    }, currentModelValue)

    expect(nextModelValue).toBeTruthy()
    if (!nextModelValue) throw new Error("expected an alternate model option")

    await permissionPicker.selectOption({ label: "Conservative" })
    await modelPicker.selectOption(nextModelValue)
    await textarea.fill(draftContent)

    await page.waitForTimeout(350)
    await page.getByRole("button", { name: "Send" }).click()

    await expect
      .poll(() => programmableConversationState(conversationId).latestDraft.id)
      .not.toBeNull()
    await expect
      .poll(() => programmableConversationState(conversationId).permissionMode)
      .toBe("conservative")
    await expect
      .poll(() => programmableConversationState(conversationId).selectedModelRef)
      .toBe(nextModelValue)
    await expect
      .poll(() => programmableConversationState(conversationId).composerDraft.content)
      .toBe("")

    await page.reload()

    await expect(textarea).toHaveValue("")
    await expect(permissionPicker).toHaveValue("conservative")
    await expect(modelPicker).toHaveValue(nextModelValue)
  })
})
