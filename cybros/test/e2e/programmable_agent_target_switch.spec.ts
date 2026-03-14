import { test, expect } from "@playwright/test"
import {
  activateProgrammableAgentRuntime,
  bundledDefaultRuntimeState,
  createHighPriorityMockProvider,
  conversationIdFromUrl,
  openNewConversation,
  programmableConversationState,
  seedProgrammableAgent,
  signIn,
  selectConversationRuntimeOption,
  waitForTailAgentToFinish,
} from "./helpers"

test.describe("Conversation agent switching", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("switching the composer agent to a programmable runtime persists and drives the next turn", async ({ page }) => {
    test.setTimeout(180_000)

    await createHighPriorityMockProvider(page)
    const suffix = `${Date.now()}-programmable`
    const programmable = seedProgrammableAgent(`E2E Switch Agent ${suffix}`)
    const deployment = activateProgrammableAgentRuntime(programmable.agentId)

    await openNewConversation(page, `Programmable Agent Switch ${suffix}`)
    await selectConversationRuntimeOption(page, "conversation-composer-agent-picker", programmable.agentName)
    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")

    await page.getByPlaceholder("Message…").fill("Use the switched programmable runtime")
    await page.getByRole("button", { name: "Send" }).click()
    await waitForTailAgentToFinish(page)

    const state = programmableConversationState(conversationIdFromUrl(page))

    expect(state.agentName).toBe(programmable.agentName)
    expect(state.latestDraft.status).toBe("finalized")
    expect(state.latestRun.state).toBe("succeeded")
    expect(state.latestRun.deploymentFingerprint).toBe(deployment.deploymentFingerprint)
  })

  test("switching back to the bundled claw agent applies to later turns", async ({ page }) => {
    test.setTimeout(180_000)

    await createHighPriorityMockProvider(page)
    const bundled = bundledDefaultRuntimeState()
    const suffix = `${Date.now()}-bundled`
    const programmable = seedProgrammableAgent(`E2E Return Agent ${suffix}`)
    activateProgrammableAgentRuntime(programmable.agentId)

    await openNewConversation(page, `Bundled Return ${suffix}`)
    await selectConversationRuntimeOption(page, "conversation-composer-agent-picker", programmable.agentName)
    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")

    await page.getByPlaceholder("Message…").fill("First programmable turn")
    await page.getByRole("button", { name: "Send" }).click()
    await waitForTailAgentToFinish(page)

    await selectConversationRuntimeOption(page, "conversation-composer-agent-picker", bundled.agentName)
    await page.getByPlaceholder("Message…").fill("Return to the bundled claw runtime")
    await page.getByRole("button", { name: "Send" }).click()
    await waitForTailAgentToFinish(page)

    const state = programmableConversationState(conversationIdFromUrl(page))

    expect(state.agentName).toBe(bundled.agentName)
    expect(state.latestDraft.status).toBe("finalized")
    expect(state.latestRun.state).toBe("succeeded")
    expect(state.latestRun.deploymentFingerprint).toBe(bundled.deploymentFingerprint)
    expect(state.latestAgentNode.outputText || "").toContain("Return to the bundled claw runtime")
  })
})
