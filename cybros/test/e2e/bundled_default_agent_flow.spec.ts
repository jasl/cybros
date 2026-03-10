import { test, expect } from "@playwright/test"
import {
  bundledDefaultRuntimeState,
  conversationIdFromUrl,
  ensureSingleBundledExecutionTarget,
  ensureOpenAiDefaultModel,
  openNewConversation,
  programmableConversationState,
  signIn,
  waitForTailAgentToFinish,
} from "./helpers"

test.describe("Bundled default agent flow", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("fresh setup bootstraps the bundled default agent and completes the first conversation loop", async ({ page }) => {
    test.setTimeout(180_000)

    ensureOpenAiDefaultModel()
    expect(ensureSingleBundledExecutionTarget().executionTargetName).toBe("Bundled Default Target")
    const bundled = bundledDefaultRuntimeState()

    expect(bundled.programName).toBe("Default")
    expect(bundled.deploymentStatus).toBe("active")
    expect(bundled.deploymentHealthStatus).toBe("healthy")
    expect(bundled.executionTargetName).toBeTruthy()

    await openNewConversation(page, `Bundled Default ${Date.now()}`)

    const conversationId = conversationIdFromUrl(page)
    let state = programmableConversationState(conversationId)

    expect(state.agentProgramName).toBe(bundled.programName)
    expect(state.defaultExecutionTargetName).toBe(bundled.executionTargetName)

    await page.getByPlaceholder("Message…").fill("Inspect the repository status")
    await page.getByRole("button", { name: "Send" }).click()
    await waitForTailAgentToFinish(page, "Bundled default agent plan:")

    state = programmableConversationState(conversationId)

    expect(state.latestDraft.status).toBe("finalized")
    expect(state.latestRun.state).toBe("succeeded")
    expect(state.latestRun.executionTargetName).toBe(bundled.executionTargetName)
    expect(state.latestRun.deploymentFingerprint).toBe(bundled.deploymentFingerprint)
    expect(state.latestAgentNode.outputText || "").toContain("Inspect the repository status")
  })
})
