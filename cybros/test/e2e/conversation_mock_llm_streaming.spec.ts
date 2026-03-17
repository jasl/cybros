import { test, expect } from "@playwright/test"
import {
  conversationIdFromUrl,
  openConversationWithMockRuntime,
  programmableConversationState,
  signIn,
} from "./helpers"

test.describe("Conversation with Mock LLM streaming + markdown", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("send creates placeholder; final markdown is durable after reload", async ({ page }) => {
    await openConversationWithMockRuntime(page, `E2E Mock LLM ${Date.now()}`)
    const transcript = page.locator("[id^='messages_list_conversation_']")
    const initialAgentBubbleCount = await transcript.locator('[data-role="agent-bubble"]').count()

    await page.getByPlaceholder("Message…").fill("!md please respond with markdown")
    await page.getByRole("button", { name: "Send" }).click()

    await expect(transcript.getByText("!md please respond with markdown", { exact: true })).toBeVisible({ timeout: 10_000 })
    await expect.poll(async () => transcript.locator('[data-role="agent-bubble"]').count(), {
      timeout: 30_000,
    }).toBeGreaterThan(initialAgentBubbleCount)

    // Placeholder exists immediately (HTTP Turbo Streams truth).
    await expect(transcript.locator('[data-role="agent-bubble"]').last()).toBeVisible()

    // Durability contract: final message must be reconstructable after refresh.
    // (Realtime delivery is covered by `conversation_mock_llm_realtime_replace.spec.ts`.)
    const deadline = Date.now() + 30_000
    while (Date.now() < deadline) {
      const tailBubble = transcript.locator('[data-role="agent-bubble"]').last()
      const state = (await tailBubble.getAttribute("data-node-state").catch(() => "")) || ""
      const hasMarkdown = (await tailBubble.locator('[data-controller="markdown"]').count().catch(() => 0)) > 0
      const hasExpectedReply = (await tailBubble.getByText("Mock Markdown", { exact: true }).count().catch(() => 0)) > 0
      if (state === "finished" && hasMarkdown && hasExpectedReply) break
      await page.waitForTimeout(750)
      await page.reload()
    }

    const markdownRoot = transcript.locator('[data-role="agent-bubble"]').last().locator('[data-controller="markdown"]')
    await expect(markdownRoot).toHaveCount(1)
    await expect(transcript.locator('[data-role="agent-bubble"]').last().getByText("Mock Markdown", { exact: true })).toBeVisible()
  })

  test("changing permission mode preserves rendered markdown", async ({ page }) => {
    test.setTimeout(150_000)

    await openConversationWithMockRuntime(page, `E2E Permission Markdown ${Date.now()}`)
    const transcript = page.locator("[id^='messages_list_conversation_']")
    const initialAgentBubbleCount = await transcript.locator('[data-role="agent-bubble"]').count()

    await page.getByPlaceholder("Message…").fill("!md permission markdown")
    await page.getByRole("button", { name: "Send" }).click()

    await expect(transcript.getByText("!md permission markdown", { exact: true })).toBeVisible({ timeout: 10_000 })
    await expect.poll(async () => transcript.locator('[data-role="agent-bubble"]').count(), {
      timeout: 30_000,
    }).toBeGreaterThan(initialAgentBubbleCount)

    const deadline = Date.now() + 30_000
    while (Date.now() < deadline) {
      const tailBubble = transcript.locator('[data-role="agent-bubble"]').last()
      const state = (await tailBubble.getAttribute("data-node-state").catch(() => "")) || ""
      const hasMarkdown = (await tailBubble.locator('[data-controller="markdown"]').count().catch(() => 0)) > 0
      const html = await tailBubble.locator('[data-markdown-target="output"]').innerHTML().catch(() => "")
      if (state === "finished" && hasMarkdown && html.includes("<h1>Mock Markdown</h1>")) break
      await page.waitForTimeout(750)
      await page.reload()
    }

    const conversationId = conversationIdFromUrl(page)
    const tailBubble = transcript.locator('[data-role="agent-bubble"]').last()
    const markdownOutput = tailBubble.locator('[data-markdown-target="output"]')

    await expect(tailBubble).toHaveAttribute("data-node-state", "finished")
    await expect(tailBubble.locator('[data-controller="markdown"]')).toHaveCount(1)
    await expect
      .poll(() => markdownOutput.innerHTML())
      .toContain("<h1>Mock Markdown</h1>")
    await expect
      .poll(() => markdownOutput.innerHTML())
      .toContain("<strong>Prompt:</strong>")

    const permissionPicker = page.getByTestId("conversation-composer-permission-picker")
    await permissionPicker.selectOption({ label: "Conservative" })
    await expect(permissionPicker).toHaveValue("conservative")
    await expect
      .poll(() => programmableConversationState(conversationId).composerDraft.permissionMode)
      .toBe("conservative")

    await expect
      .poll(() => markdownOutput.innerHTML())
      .toContain("<h1>Mock Markdown</h1>")
    await expect
      .poll(() => markdownOutput.innerHTML())
      .toContain("<strong>Prompt:</strong>")
  })
})
