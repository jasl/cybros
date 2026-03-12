import { test, expect } from "@playwright/test"
import { signIn, openConversationWithMockRuntime } from "./helpers"

async function addHiddenComposerInput(page, { name, value }) {
  await page.locator('form[data-controller~="message-form"]').evaluate(
    (form, { inputName, inputValue }) => {
      let input = form.querySelector(`input[name="${inputName}"]`)
      if (!(input instanceof HTMLInputElement)) {
        input = document.createElement("input")
        input.type = "hidden"
        input.name = inputName
        form.appendChild(input)
      }

      input.disabled = false
      input.value = inputValue
    },
    { inputName: name, inputValue: String(value) },
  )
}

test.describe("Conversation rapid sends ordering", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("rapid sends preserve message ordering and do not lose drafts", async ({ page }) => {
    test.setTimeout(150_000)

    await openConversationWithMockRuntime(page, `E2E Rapid Sends ${Date.now()}`)
    await addHiddenComposerInput(page, {
      name: "input_policy_override[input_coalescing][window_ms]",
      value: 0,
    })

    const messages = [`rapid-1-${Date.now()}`, `rapid-2-${Date.now()}`, `rapid-3-${Date.now()}`]
    const anchorPrompt = "!mock slow=0.05 -- queue anchor " + "slow ".repeat(80)
    const userTexts = page.locator('[data-role="user-text"]')

    await page.getByPlaceholder("Message…").fill(anchorPrompt)
    await page.getByRole("button", { name: "Send" }).click()
    await expect(page.getByText(anchorPrompt)).toBeVisible({ timeout: 10_000 })

    for (const msg of messages) {
      await page.getByPlaceholder("Message…").fill(msg)
      await page.getByRole("button", { name: "Send" }).click()
    }

    await expect(userTexts).toHaveText([anchorPrompt, ...messages], { timeout: 30_000 })
  })
})
