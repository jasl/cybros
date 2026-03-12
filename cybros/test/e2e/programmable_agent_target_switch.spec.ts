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

async function openProgrammableConversation(page, suffix: string) {
  ensureOpenAiDefaultModel()
  const program = seedProgrammableAgentProgram(`E2E Target Switch Program ${suffix}`)
  const targets = seedExecutionTargets(`target-switch-${suffix}`, true)
  seedActiveProgrammableDeployment(program.programId)

  await openNewConversation(page, `Programmable Target Switch ${suffix}`)
  await selectConversationRuntimeOption(page, "conversation-composer-agent-picker", program.programName)
  await selectConversationRuntimeOption(page, "conversation-composer-execution-target-picker", targets.primaryTargetName)

  return { program, targets }
}

test.describe("Programmable agent target switching", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("default mode confirms a visible target switch and finalizes the alternate target after approval", async ({ page }) => {
    test.setTimeout(180_000)

    const suffix = `${Date.now()}-default`
    const { targets } = await openProgrammableConversation(page, suffix)
    await selectConversationRuntimeOption(page, "conversation-composer-permission-picker", "Default")
    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")

    await page.getByPlaceholder("Message…").fill("[fixture:switch-target]")
    await page.getByRole("button", { name: "Send" }).click()

    await waitForTailAgentState(page, "awaiting_approval")
    let state = programmableConversationState(conversationIdFromUrl(page))
    expect(state.latestDraft.status).toBe("awaiting_approval")
    expect(state.latestDraft.proposedExecutionTargetName).toBe(targets.alternateTargetName)

    await page.getByRole("button", { name: "Approve" }).last().click()
    await waitForTailAgentToFinish(page)

    state = programmableConversationState(conversationIdFromUrl(page))
    expect(state.defaultExecutionTargetName).toBe(targets.alternateTargetName)
    expect(state.latestRun.executionTargetName).toBe(targets.alternateTargetName)
  })

  test("full access auto-allows a visible target switch without parking for approval", async ({ page }) => {
    test.setTimeout(180_000)

    const suffix = `${Date.now()}-full`
    const { targets } = await openProgrammableConversation(page, suffix)
    await selectConversationRuntimeOption(page, "conversation-composer-permission-picker", "Full access")
    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")

    await page.getByPlaceholder("Message…").fill("[fixture:switch-target]")
    await page.getByRole("button", { name: "Send" }).click()

    await waitForTailAgentToFinish(page)
    await expect(page.getByRole("button", { name: "Approve" })).toHaveCount(0)

    const state = programmableConversationState(conversationIdFromUrl(page))
    expect(state.latestDraft.status).toBe("finalized")
    expect(state.defaultExecutionTargetName).toBe(targets.alternateTargetName)
    expect(state.latestRun.executionTargetName).toBe(targets.alternateTargetName)
  })
})
