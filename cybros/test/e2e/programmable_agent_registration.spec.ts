import { test, expect } from "@playwright/test"
import {
  conversationIdFromUrl,
  deactivateProgramDeployments,
  ensureOpenAiDefaultModel,
  openNewConversation,
  programmableConversationState,
  requireProgrammableAgentFixtureUrl,
  seedExecutionTargets,
  seedProgrammableAgentProgram,
  signIn,
  selectConversationRuntimeOption,
  waitForTailAgentToFinish,
} from "./helpers"

test.describe("Programmable agent registration", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("registers, inspects, activates, selects, and runs a programmable agent, then surfaces activation drift as stale selection", async ({ page }) => {
    test.setTimeout(180_000)

    ensureOpenAiDefaultModel()
    const suffix = Date.now().toString()
    const fixtureUrl = requireProgrammableAgentFixtureUrl()
    const program = seedProgrammableAgentProgram(`E2E Registration Program ${suffix}`)
    const targets = seedExecutionTargets(`registration-${suffix}`, false)

    await page.goto("/system/settings/agent_deployments")
    await page.getByRole("link", { name: "Register deployment" }).click()

    await page.getByLabel("Agent program").selectOption({ label: program.programName })
    await page.getByLabel("Endpoint URL").fill(fixtureUrl)
    await page.getByLabel("Deployment bearer").fill("secret://fixture")
    await page.getByLabel("Expected deployment fingerprint").fill("fixture-deployment-v1")
    await page.getByRole("button", { name: "Register" }).click()

    await expect(page.getByRole("heading", { name: program.programName })).toBeVisible()
    await expect(page.locator("main")).toContainText("Source kind")
    await expect(page.locator("main")).toContainText("Custom")
    await expect(page.locator("main")).toContainText("Launch owner")
    await expect(page.locator("main")).toContainText("Operator-managed external deployment")
    await expect(page.locator("main")).toContainText("Launch status")
    await expect(page.locator("main")).toContainText("Registered endpoint")
    await expect(page.locator("main")).toContainText("inactive")
    await expect(page.locator("main")).toContainText("unknown")
    await expect(page.locator("main")).toContainText(fixtureUrl)

    await page.getByRole("button", { name: "Inspect" }).click()
    await expect(page.locator("main")).toContainText("healthy")

    await page.getByRole("button", { name: "Activate" }).click()
    await expect(page.locator("main")).toContainText("active")
    await expect(page.locator("main")).toContainText("Externally launched")

    await openNewConversation(page, `Programmable Registration ${suffix}`)
    await selectConversationRuntimeOption(page, "conversation-composer-agent-picker", program.programName)
    await selectConversationRuntimeOption(page, "conversation-composer-permission-picker", "Full access")
    await selectConversationRuntimeOption(page, "conversation-composer-execution-target-picker", targets.primaryTargetName)

    await page.getByPlaceholder("Message…").fill("registration smoke")
    await page.getByRole("button", { name: "Send" }).click()
    await waitForTailAgentToFinish(page, "fixture compose response")

    const conversationId = conversationIdFromUrl(page)
    const state = programmableConversationState(conversationId)

    expect(state.agentProgramName).toBe(program.programName)
    expect(state.defaultExecutionTargetName).toBe(targets.primaryTargetName)
    expect(state.latestRun.executionTargetName).toBe(targets.primaryTargetName)
    expect(state.latestRun.deploymentFingerprint).toBe("fixture-deployment-v1")

    deactivateProgramDeployments(program.programId)
    await page.reload()

    await expect(page.getByTestId("conversation-agent-stale-warning")).toBeVisible()
  })
})
