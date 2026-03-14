import { test, expect } from "@playwright/test"
import {
  bundledDefaultRuntimeState,
  createHighPriorityMockProvider,
  conversationIdFromUrl,
  openNewConversation,
  programmableConversationState,
  selectConversationRuntimeOption,
  signIn,
  waitForTailAgentToFinish,
} from "./helpers"

test.describe("Bundled claw agent flow", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("fresh setup bootstraps the bundled claw agent and completes the first conversation loop", async ({ page }) => {
    test.setTimeout(180_000)

    await createHighPriorityMockProvider(page)
    const bundled = bundledDefaultRuntimeState()

    expect(bundled.agentName).toBe("Claw")
    expect(bundled.deploymentStatus).toBe("active")
    expect(bundled.deploymentHealthStatus).toBe("healthy")

    await openNewConversation(page, `Bundled Claw ${Date.now()}`)

    const conversationId = conversationIdFromUrl(page)
    let state = programmableConversationState(conversationId)

    expect(state.agentName).toBe(bundled.agentName)

    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")
    await page.getByPlaceholder("Message…").fill("Inspect the repository status")
    await page.getByRole("button", { name: "Send" }).click()
    await waitForTailAgentToFinish(page, "Inspect the repository status")

    state = programmableConversationState(conversationId)

    expect(state.latestDraft.status).toBe("finalized")
    expect(state.latestRun.state).toBe("succeeded")
    expect(state.latestRun.deploymentFingerprint).toBe(bundled.deploymentFingerprint)
    expect(state.latestAgentNode.outputText || "").toContain("Inspect the repository status")
  })
})
