import { test, expect } from "@playwright/test"
import {
  bundledDefaultRuntimeState,
  conversationIdFromUrl,
  ensureOpenAiDefaultModel,
  openNewConversation,
  programmableConversationState,
  signIn,
} from "./helpers"

const WELCOME_TEXT = "I’m Cybros. I’ll track state in the DAG and keep follow-up work explicit."
const FIRST_USER_MESSAGE = "Explain how hook cutover works."
const EXPECTED_TITLE = "Explain how hook cutover works"

async function waitForConversationTitle(conversationId: string, expectedTitle: string, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    if (programmableConversationState(conversationId).title === expectedTitle) {
      return
    }

    await new Promise((resolve) => setTimeout(resolve, 500))
  }

  expect(programmableConversationState(conversationId).title).toBe(expectedTitle)
}

test.describe("Bootstrap hooks", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("new main conversations render a welcome message and title the conversation from the first user message", async ({ page }) => {
    test.setTimeout(180_000)

    ensureOpenAiDefaultModel()
    const bundled = bundledDefaultRuntimeState()
    expect(bundled.agentName).toBe("Default")

    await openNewConversation(page, "Conversation")

    const conversationId = conversationIdFromUrl(page)

    await expect.poll(() => programmableConversationState(conversationId).latestAgentNode.outputText || "", {
      timeout: 30_000,
    }).toContain(WELCOME_TEXT)
    await expect(page.getByText("Interactive programmable runtime requires a materialized ConversationRun.")).toHaveCount(0)

    await page.getByPlaceholder("Message…").fill(FIRST_USER_MESSAGE)
    await page.getByRole("button", { name: "Send" }).click()
    await expect.poll(() => programmableConversationState(conversationId).latestRun.state, {
      timeout: 120_000,
    }).toBe("succeeded")
    await waitForConversationTitle(conversationId, EXPECTED_TITLE)

    await page.reload()
    await expect(page.locator("header").getByText(EXPECTED_TITLE)).toBeVisible()
  })
})
