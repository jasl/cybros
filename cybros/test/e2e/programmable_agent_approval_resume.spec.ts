import { test, expect } from "@playwright/test"
import {
  conversationIdFromUrl,
  ensureOpenAiDefaultModel,
  openNewConversation,
  programmableConversationState,
  seedActiveProgrammableDeployment,
  seedExecutionTargets,
  seedProgrammableAgentProgram,
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

    ensureOpenAiDefaultModel()
    const suffix = Date.now().toString()
    const program = seedProgrammableAgentProgram(`E2E Approval Program ${suffix}`)
    const targets = seedExecutionTargets(`approval-${suffix}`, false)
    seedActiveProgrammableDeployment(program.programId)

    await openNewConversation(page, `Programmable Approval ${suffix}`)
    await selectConversationRuntimeOption(page, "conversation-composer-agent-picker", program.programName)
    await selectConversationRuntimeOption(page, "conversation-composer-permission-picker", "Default")
    await selectConversationRuntimeOption(page, "conversation-composer-execution-target-picker", targets.primaryTargetName)

    await page.getByPlaceholder("Message…").fill("[fixture:stage-state] [fixture:replay-kv] [fixture:approval]")
    await page.getByRole("button", { name: "Send" }).click()

    await waitForTailAgentState(page, "awaiting_approval")
    await expect(page.getByRole("button", { name: "Approve" }).last()).toBeVisible()

    await page.getByRole("button", { name: "Approve" }).last().click()
    await waitForTailAgentToFinish(page, "fixture compose response")

    const state = programmableConversationState(conversationIdFromUrl(page))

    expect(state.latestDraft.status).toBe("finalized")
    expect(state.latestDraft.approvalStatus).toBe("approved")
    expect(state.publicSettings.tone).toBe("concise")
    expect(state.selectedAgentConfig.mode).toBe("review")
    expect(state.kv["shared.fixture.plan"]).toEqual({ status: "planned" })
    expect(state.kv["shared.fixture.replay"]).toEqual({ status: "deduped" })
    expect(state.latestDraft.operationReceiptCounts["fixture-kv-replay"]).toBe(1)
  })
})
