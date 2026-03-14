import { test, expect } from "@playwright/test"
import {
  activateProgrammableAgentRuntime,
  createHighPriorityMockProvider,
  conversationIdFromUrl,
  openNewConversation,
  programmableConversationState,
  seedProgrammableAgent,
  signIn,
  selectConversationRuntimeOption,
  waitForTailAgentState,
  waitForTailAgentToFinish,
} from "./helpers"

test.describe("Programmable agent approval resume", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("parks for approval, resumes locally, and commits replay-safe callback staging exactly once", async ({ page }) => {
    test.setTimeout(180_000)

    await createHighPriorityMockProvider(page)
    const suffix = Date.now().toString()
    const agent = seedProgrammableAgent(`E2E Approval Agent ${suffix}`)
    activateProgrammableAgentRuntime(agent.agentId)

    await openNewConversation(page, `Programmable Approval ${suffix}`, agent.agentName)
    await selectConversationRuntimeOption(page, "conversation-composer-permission-picker", "Default")
    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")

    await page.getByPlaceholder("Message…").fill("[fixture:stage-state] [fixture:replay-kv] [fixture:approval]")
    await page.getByRole("button", { name: "Send" }).click()

    await waitForTailAgentState(page, "awaiting_approval")
    await expect(page.getByRole("button", { name: "Approve" }).last()).toBeVisible()

    await page.getByRole("button", { name: "Approve" }).last().click()
    await waitForTailAgentToFinish(page)

    const state = programmableConversationState(conversationIdFromUrl(page))

    expect(state.latestDraft.status).toBe("finalized")
    expect(state.latestDraft.approvalStatus).toBe("approved")
    expect(state.publicSettings.tone).toBe("concise")
    expect(state.selectedAgentConfig.mode).toBe("review")
    expect(state.kv["shared.fixture.plan"]).toEqual({ status: "planned" })
    expect(state.kv["shared.fixture.replay"]).toEqual({ status: "deduped" })
    expect(state.kvEntryCounts["shared.fixture.plan"]).toBe(1)
    expect(state.kvEntryCounts["shared.fixture.replay"]).toBe(1)
  })
})
