import { execFileSync } from "node:child_process"
import { type Page, expect } from "@playwright/test"

export async function signIn(page: Page, email = "admin@example.com", password = "Passw0rd") {
  await page.goto("/session/new")

  // Fresh dev DB redirects to setup wizard.
  const setupHeading = page.getByRole("heading", { name: "Set up Cybros" })
  if (await setupHeading.isVisible().catch(() => false)) {
    await page.getByLabel("Email").fill(email)
    await page.getByLabel("Password", { exact: true }).fill(password)
    await page.getByLabel("Confirm password").fill(password)
    await page.getByRole("button", { name: "Create account" }).click()
    await page.waitForURL("**/dashboard")
    return
  }

  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password", { exact: true }).fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await page.waitForURL("**/dashboard")
}

export async function createHighPriorityMockProvider(page: Page) {
  const result = railsJson<{ defaultModelRef: string }>(`
    require "json"

    credential = LLMProviderCredential.find_or_initialize_by(provider_key: "openai", status: "active")
    credential.assign_attributes(
      credential_type: "api_key",
      api_key: "sk-test",
      max_concurrent_requests: 3,
      requests_per_minute: 90,
      tokens_per_minute: 180000,
      burst_limit: 6,
      backoff_policy: { "kind" => "exponential", "base_delay_ms" => 250, "max_delay_ms" => 10000 },
    )
    credential.save!

    Account.instance.update_llm_default_model_ref!("dev/mock-model")

    puts JSON.generate({ defaultModelRef: Account.instance.llm_default_model_ref })
  `)
  const bundled = bundledDefaultRuntimeState()

  expect(result.defaultModelRef).toBe("dev/mock-model")
  expect(bundled.agentName).toBeTruthy()
}

function railsRunner(script: string): string {
  return execFileSync("bin/rails", ["runner", script], {
    cwd: process.cwd(),
    encoding: "utf8",
    env: {
      ...process.env,
      RAILS_ENV: "development",
    },
  }).trim()
}

export function railsJson<T>(script: string): T {
  const output = railsRunner(script)
  return JSON.parse(output) as T
}

export function requireProgrammableAgentFixtureUrl(): string {
  const url = String(process.env.PROGRAMMABLE_AGENT_FIXTURE_URL || "").trim()
  if (!url) {
    throw new Error("PROGRAMMABLE_AGENT_FIXTURE_URL is required for programmable-agent E2E tests")
  }

  return url
}

export function ensureOpenAiDefaultModel() {
  return railsJson<{ defaultModelRef: string }>(`
    require "json"

    credential = LLMProviderCredential.find_or_initialize_by(provider_key: "openai", status: "active")
    credential.assign_attributes(
      credential_type: "api_key",
      api_key: "sk-test",
      max_concurrent_requests: 3,
      requests_per_minute: 90,
      tokens_per_minute: 180000,
      burst_limit: 6,
      backoff_policy: { "kind" => "exponential", "base_delay_ms" => 250, "max_delay_ms" => 10000 },
    )
    credential.save!

    Account.instance.update_llm_default_model_ref!("openai/gpt-5.4")

    puts JSON.generate({ defaultModelRef: Account.instance.llm_default_model_ref })
  `)
}

export function seedProgrammableAgent(name: string) {
  return railsJson<{ agentId: string; agentName: string }>(`
    require "json"

    agent = Agent.create!(
      name: ${JSON.stringify(name)},
      description: "Programmable fixture agent",
      source_kind: "custom",
      local_path: "storage/agents/#{SecureRandom.hex(4)}",
      config_namespace: "fixture.agent.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:v1",
      max_concurrent_tasks: 4,
      max_queued_tasks: 16,
      default_timeout_s: 900,
      manifest_snapshot: {
        "agent_key" => "fixture-program",
        "name" => ${JSON.stringify(name)},
      },
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      config_schema_fingerprint: "config:v1",
    )

    puts JSON.generate({
      agentId: agent.id,
      agentName: agent.name,
    })
  `)
}

export function activateProgrammableAgentRuntime(agentId: string, endpointUrl = requireProgrammableAgentFixtureUrl()) {
  return railsJson<{ deploymentId: string; deploymentFingerprint: string; agentId: string; agentName: string }>(`
    require "json"

    agent = Agent.find(${JSON.stringify(agentId)})
    now = Time.current.change(usec: 0)

    agent.update!(
      transport_kind: "http_jsonrpc",
      endpoint_url: ${JSON.stringify(endpointUrl)},
      deployment_bearer_secret_ref: "secret://fixture",
      deployment_fingerprint: "fixture-deployment-v1",
      status: "active",
      health_status: "healthy",
      protocol_version: "agent_rpc.v1",
      agent_sdk_version: "fixture-ruby-sdk/1.0",
      supported_methods: Agents::Protocol::REQUIRED_METHODS,
      capability_snapshot: {
        "observed_runtime_identity" => {
          "supported_methods" => Agents::Protocol::REQUIRED_METHODS,
        },
      },
      inspection_details: {},
      transport_config: {},
      activated_at: now,
      last_health_checked_at: now,
      last_inspected_at: now,
    )

    recognized = RecognizedDeployment.recognize!(
      agent: agent,
      deployment: agent,
      capability_snapshot: {},
    )

    puts JSON.generate({
      deploymentId: recognized.id,
      deploymentFingerprint: agent.deployment_fingerprint,
      agentId: agent.id,
      agentName: agent.name,
    })
  `)
}

export function programmableConversationState(conversationId: string) {
  return railsJson<{
    conversationId: string
    title: string
    selectedModelRef: string | null
    agentName: string | null
    permissionMode: string
    composerDraft: {
      content: string
      modelRef: string | null
      permissionMode: string | null
    }
    publicSettings: Record<string, unknown>
    selectedAgentConfig: Record<string, unknown>
    kv: Record<string, unknown>
    kvEntryCounts: Record<string, number>
    latestDraft: {
      id: string | null
      status: string | null
      approvalStatus: string | null
      operationReceiptCounts: Record<string, number>
    }
    latestRun: {
      id: string | null
      state: string | null
      deploymentFingerprint: string | null
    }
    latestAgentNode: {
      id: string | null
      state: string | null
      outputText: string | null
      outputPreviewText: string | null
    }
    laneTaskNames: string[]
  }>(`
    require "json"

    conversation = Conversation.find(${JSON.stringify(conversationId)})
    draft = conversation.run_drafts.order(created_at: :desc).first
    latest_run = ConversationRun.where(conversation: conversation).order(created_at: :desc).first
    latest_agent =
      conversation.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::AgentMessage.node_type_key)
        .order(:id)
        .last
    lane_task_names =
      conversation.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::Task.node_type_key)
        .order(:id)
        .map { |node| node.body_input["name"].to_s }
    invocation =
      if draft.present?
        AgentRPCInvocation.where(scope_type: "run_draft", scope_id: draft.id).order(created_at: :desc).first
      end

    kv = conversation.chat_lane.lane_kv_entries.order(:key).each_with_object({}) do |entry, out|
      out[entry.key] = entry.value
    end
    kv_entry_counts = conversation.chat_lane.lane_kv_entries.group(:key).count
    composer_draft = conversation.resolved_composer_draft

    puts JSON.generate({
      conversationId: conversation.id,
      title: conversation.title,
      selectedModelRef: conversation.metadata.dig("llm", "model_ref").to_s.presence,
      agentName: conversation.agent&.name,
      permissionMode: conversation.permission_mode,
      composerDraft: {
        content: composer_draft["content"].to_s,
        modelRef: composer_draft["model_ref"].to_s.presence,
        permissionMode: composer_draft["permission_mode"].to_s.presence,
      },
      publicSettings: conversation.public_settings,
      selectedAgentConfig: conversation.selected_agent_config,
      kv: kv,
      kvEntryCounts: kv_entry_counts,
      latestDraft: {
        id: draft&.id,
        status: draft&.status,
        approvalStatus: draft&.approval_state&.dig("status"),
        operationReceiptCounts: invocation.present? ? invocation.agent_rpc_operation_receipts.group(:operation_id).count : {},
      },
      latestRun: {
        id: latest_run&.id,
        state: latest_run&.state,
        deploymentFingerprint: latest_run&.deployment_fingerprint,
      },
      latestAgentNode: {
        id: latest_agent&.id,
        state: latest_agent&.state,
        outputText: latest_agent&.body&.output&.dig("content"),
        outputPreviewText: latest_agent&.body&.output_preview&.dig("content"),
      },
      laneTaskNames: lane_task_names,
    })
  `)
}

export function bundledDefaultRuntimeState() {
  return railsJson<{
    agentId: string
    agentName: string
    deploymentId: string | null
    deploymentFingerprint: string | null
    deploymentStatus: string | null
    deploymentHealthStatus: string | null
  }>(`
    require "json"

    agent = Agents::BootstrapBundledDefaultService.bootstrap!
    deployment = agent.active_healthy_deployment_for_published_contract

    puts JSON.generate({
      agentId: agent.id,
      agentName: agent.name,
      deploymentId: deployment&.id,
      deploymentFingerprint: deployment&.deployment_fingerprint,
      deploymentStatus: deployment&.status,
      deploymentHealthStatus: deployment&.health_status,
    })
  `)
}

export function conversationIdFromUrl(page: Page): string {
  const match = page.url().match(/\/conversations\/([^/?#]+)/)
  if (!match) {
    throw new Error(`Conversation URL missing id: ${page.url()}`)
  }

  return match[1]
}

export async function openNewConversation(page: Page, _title: string, agentName?: string) {
  await page.goto("/dashboard")

  const agentRows = page.getByTestId("dashboard-agent-row")
  const row =
    agentRows.filter({ has: page.getByText(agentName ?? "Claw", { exact: true }) }).first()

  await expect(row).toBeVisible()
  await row.getByRole("button", { name: "New conversation" }).click()
  await expect(page).toHaveURL(/\/conversations\//)
}

export async function openConversationWithMockRuntime(page: Page, title: string) {
  await createHighPriorityMockProvider(page)
  await openNewConversation(page, title)
  await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")
}

function conversationRuntimeOptionPersisted({
  conversationId,
  testId,
  expectedValue,
}: {
  conversationId: string
  testId: string
  expectedValue: string | null
}) {
  const state = programmableConversationState(conversationId)

  switch (testId) {
    case "conversation-composer-model-picker":
      return state.composerDraft.modelRef === expectedValue
    case "conversation-composer-permission-picker":
      return state.composerDraft.permissionMode === expectedValue
    default:
      throw new Error(`unsupported runtime option picker: ${testId}`)
  }
}

export async function selectConversationRuntimeOption(page: Page, testId: string, label: string) {
  const conversationId = conversationIdFromUrl(page)
  const locator = page.getByTestId(testId)
  const expectedValue = await locator.locator("option").evaluateAll((options, targetLabel) => {
    const match = options.find((option) => {
      const text = option.textContent?.trim() || ""
      return option.label === targetLabel || text === targetLabel
    })

    return match ? match.value : null
  }, label)

  if (expectedValue === null) {
    throw new Error(`runtime option ${testId} is missing label ${label}`)
  }

  await locator.selectOption({ label })

  await expect(locator).toHaveValue(expectedValue)

  const deadline = Date.now() + 15_000
  while (Date.now() < deadline) {
    if (conversationRuntimeOptionPersisted({ conversationId, testId, expectedValue })) {
      await page.reload({ waitUntil: "domcontentloaded" })
      return
    }

    await page.waitForTimeout(250)
  }

  throw new Error(`runtime option ${testId} did not persist as ${label}`)
}

export async function waitForTailAgentState(page: Page, state: string, timeoutMs = 90_000) {
  const conversationId = conversationIdFromUrl(page)
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const currentState = programmableConversationState(conversationId).latestAgentNode.state || ""
    if (currentState === state) {
      await page.goto(page.url())
      await expect(page.locator('[data-role="agent-bubble"]').last()).toHaveAttribute("data-node-state", state)
      return
    }

    await page.waitForTimeout(750)
  }

  await expect(page.locator('[data-role="agent-bubble"]').last()).toHaveAttribute("data-node-state", state)
}

export async function waitForTailAgentToFinish(page: Page, expectedText?: string, timeoutMs = 120_000) {
  const conversationId = conversationIdFromUrl(page)
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const latestAgentNode = programmableConversationState(conversationId).latestAgentNode
    const currentState = latestAgentNode.state || ""
    const outputText = latestAgentNode.outputText || latestAgentNode.outputPreviewText || ""
    const textSatisfied = expectedText ? outputText.includes(expectedText) : outputText.trim().length > 0

    if (currentState === "finished" && textSatisfied) {
      await page.goto(page.url())
      await expect(page.locator('[data-role="agent-bubble"]').last()).toHaveAttribute("data-node-state", "finished")
      if (expectedText) {
        await expect(page.locator('[data-role="agent-bubble"]').last()).toContainText(expectedText)
      }
      return
    }

    await page.waitForTimeout(750)
  }

  await expect(page.locator('[data-role="agent-bubble"]').last()).toHaveAttribute("data-node-state", "finished")
  if (expectedText) {
    await expect(page.locator('[data-role="agent-bubble"]').last()).toContainText(expectedText)
  }
}
