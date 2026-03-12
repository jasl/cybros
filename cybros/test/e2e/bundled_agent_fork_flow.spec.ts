import { test, expect } from "@playwright/test"
import {
  agentProgramStateByName,
  bundledDefaultRuntimeState,
  createHighPriorityMockProvider,
  conversationIdFromUrl,
  ensureSingleBundledExecutionTarget,
  openNewConversation,
  programmableConversationState,
  selectConversationRuntimeOption,
  signIn,
  waitForTailAgentToFinish,
} from "./helpers"

test.describe("Bundled agent fork flow", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("operator can fork the bundled default agent and run the first forked conversation loop", async ({ page }) => {
    test.setTimeout(180_000)

    await createHighPriorityMockProvider(page)
    const runtimeTarget = ensureSingleBundledExecutionTarget()
    expect(runtimeTarget.executionTargetName).toBeTruthy()
    const bundled = bundledDefaultRuntimeState()
    const forkName = `Forked Agent ${Date.now()}`

    expect(bundled.executionTargetName).toBe(runtimeTarget.executionTargetName)

    await page.goto(`/system/settings/agent_programs/${bundled.programId}`)
    await page.getByLabel("Fork name").fill(forkName)
    await page.getByRole("button", { name: "Copy as custom agent" }).click()
    await expect(page.getByRole("heading", { name: forkName })).toBeVisible()

    const forked = agentProgramStateByName(forkName)
    expect(forked.selectable).toBe(true)
    expect(forked.sourceKind).toBe("custom")
    expect(forked.forkedFromProgramId).toBe(bundled.programId)
    expect(forked.activeDeploymentStatus).toBe("active")
    expect(forked.activeDeploymentHealthStatus).toBe("healthy")

    await openNewConversation(page, `Forked Conversation ${Date.now()}`)
    await selectConversationRuntimeOption(page, "conversation-composer-agent-picker", forkName)

    const conversationId = conversationIdFromUrl(page)
    const initialState = programmableConversationState(conversationId)
    if (!initialState.defaultExecutionTargetName && bundled.executionTargetName) {
      await selectConversationRuntimeOption(page, "conversation-composer-execution-target-picker", bundled.executionTargetName)
    }
    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")

    await page.getByPlaceholder("Message…").fill("Review the current worktree")
    await page.getByRole("button", { name: "Send" }).click()
    await waitForTailAgentToFinish(page, "Review the current worktree")

    const state = programmableConversationState(conversationId)

    expect(state.agentProgramName).toBe(forkName)
    expect(state.latestDraft.status).toBe("finalized")
    expect(state.latestRun.state).toBe("succeeded")
    expect(state.latestRun.deploymentFingerprint).toBe(forked.activeDeploymentFingerprint)
    expect(state.latestAgentNode.outputText || "").toContain("Review the current worktree")
  })
})
