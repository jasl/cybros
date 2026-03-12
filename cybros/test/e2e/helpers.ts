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
  const target = ensureSingleBundledExecutionTarget()

  expect(result.defaultModelRef).toBe("dev/mock-model")
  expect(target.executionTargetName).toBeTruthy()
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

export function seedProgrammableAgentProgram(name: string) {
  return railsJson<{ programId: string; programName: string }>(`
    require "json"

    program = AgentProgram.create!(
      name: ${JSON.stringify(name)},
      config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:v1",
      manifest_snapshot: {
        "agent_program_key" => "fixture-program",
        "name" => ${JSON.stringify(name)},
      },
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      config_schema_fingerprint: "config:v1",
    )

    puts JSON.generate({
      programId: program.id,
      programName: program.name,
    })
  `)
}

export function seedExecutionTargets(prefix: string, includeAlternate = true) {
  return railsJson<{
    primaryTargetId: string
    primaryTargetName: string
    alternateTargetId: string | null
    alternateTargetName: string | null
  }>(`
    require "json"

    location = ExecutionLocation.create!(
      name: ${JSON.stringify(`${prefix} host`)},
      kind: "host",
      platform: "macos_arm64",
      status: "active",
      trust_group: "operator",
      environment: "development",
      tags: ["fixture"],
      max_concurrent_tasks: 4,
      max_queued_tasks: 16,
      default_timeout_s: 900,
    )

    workspace = Workspace.create!(
      execution_location: location,
      name: ${JSON.stringify(`${prefix} workspace`)},
      root_path: "/tmp/${prefix.toLowerCase().replace(/[^a-z0-9]+/g, "-")}-#{SecureRandom.hex(4)}",
      workspace_type: "git",
      status: "active",
      capability_tags: ["git"],
      tags: ["fixture"],
    )

    primary = ExecutionTarget.create!(
      execution_location: location,
      workspace: workspace,
      name: ${JSON.stringify(`${prefix} Primary`)},
      status: "active",
      sandboxed: true,
    )

    alternate =
      if ${includeAlternate ? "true" : "false"}
        alternate_location = ExecutionLocation.create!(
          name: ${JSON.stringify(`${prefix} alternate host`)},
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )

        alternate_workspace = Workspace.create!(
          execution_location: alternate_location,
          name: ${JSON.stringify(`${prefix} alternate workspace`)},
          root_path: "/tmp/${prefix.toLowerCase().replace(/[^a-z0-9]+/g, "-")}-alt-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

        ExecutionTarget.create!(
          execution_location: alternate_location,
          workspace: alternate_workspace,
          name: ${JSON.stringify(`${prefix} Alternate`)},
          status: "active",
          sandboxed: true,
          max_concurrent_tasks_override: 2,
          max_queued_tasks_override: 5,
          default_timeout_s_override: 600,
        )
      end

    puts JSON.generate({
      primaryTargetId: primary.id,
      primaryTargetName: primary.name,
      alternateTargetId: alternate&.id,
      alternateTargetName: alternate&.name,
    })
  `)
}

export function seedActiveProgrammableDeployment(programId: string, endpointUrl = requireProgrammableAgentFixtureUrl()) {
  return railsJson<{ deploymentId: string }>(`
    require "json"

    program = AgentProgram.find(${JSON.stringify(programId)})
    program.agent_deployments.where(status: "active").update_all(
      status: "inactive",
      deactivated_at: Time.current,
      updated_at: Time.current,
    )

    deployment = AgentDeployment.create!(
      agent_program: program,
      transport_kind: "http_jsonrpc",
      endpoint_url: ${JSON.stringify(endpointUrl)},
      deployment_bearer_secret_ref: "secret://fixture",
      contract_fingerprint: program.published_contract_fingerprint,
      deployment_fingerprint: "fixture-deployment-v1",
      status: "active",
      health_status: "healthy",
      protocol_version: "agent_rpc.v1",
      agent_sdk_version: "fixture-ruby-sdk/1.0",
      supported_methods: AgentDeployments::REQUIRED_METHODS,
      manifest_snapshot: {},
      schema_snapshot: {},
      capability_snapshot: {},
      inspection_details: {},
      activated_at: Time.current.change(usec: 0),
    )

    puts JSON.generate({ deploymentId: deployment.id })
  `)
}

export function deactivateProgramDeployments(programId: string) {
  return railsJson<{ deactivated: number }>(`
    require "json"

    deactivated =
      AgentDeployment.where(agent_program_id: ${JSON.stringify(programId)}, status: "active").update_all(
        status: "inactive",
        deactivated_at: Time.current,
        updated_at: Time.current,
      )

    puts JSON.generate({ deactivated: deactivated })
  `)
}

export function programmableConversationState(conversationId: string) {
  return railsJson<{
    conversationId: string
    title: string
    selectedModelRef: string | null
    agentProgramName: string | null
    permissionMode: string
    defaultExecutionTargetId: string | null
    defaultExecutionTargetName: string | null
    publicSettings: Record<string, unknown>
    selectedAgentConfig: Record<string, unknown>
    kv: Record<string, unknown>
    kvEntryCounts: Record<string, number>
    latestDraft: {
      id: string | null
      status: string | null
      approvalStatus: string | null
      proposedExecutionTargetId: string | null
      proposedExecutionTargetName: string | null
      operationReceiptCounts: Record<string, number>
    }
    latestRun: {
      id: string | null
      state: string | null
      executionTargetId: string | null
      executionTargetName: string | null
      deploymentFingerprint: string | null
    }
    latestAgentNode: {
      id: string | null
      state: string | null
      outputText: string | null
      outputPreviewText: string | null
    }
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
    invocation =
      if draft.present?
        AgentRPCInvocation.where(scope_type: "run_draft", scope_id: draft.id).order(created_at: :desc).first
      end

    kv = conversation.chat_lane.lane_kv_entries.order(:key).each_with_object({}) do |entry, out|
      out[entry.key] = entry.value
    end
    kv_entry_counts = conversation.chat_lane.lane_kv_entries.group(:key).count

    puts JSON.generate({
      conversationId: conversation.id,
      title: conversation.title,
      selectedModelRef: conversation.metadata.dig("llm", "model_ref").to_s.presence,
      agentProgramName: conversation.agent_program&.name,
      permissionMode: conversation.permission_mode,
      defaultExecutionTargetId: conversation.default_execution_target_id,
      defaultExecutionTargetName: conversation.default_execution_target&.name,
      publicSettings: conversation.public_settings,
      selectedAgentConfig: conversation.selected_agent_config,
      kv: kv,
      kvEntryCounts: kv_entry_counts,
      latestDraft: {
        id: draft&.id,
        status: draft&.status,
        approvalStatus: draft&.approval_state&.dig("status"),
        proposedExecutionTargetId: draft&.proposed_execution_target_id,
        proposedExecutionTargetName: draft&.proposed_execution_target&.name,
        operationReceiptCounts: invocation.present? ? invocation.agent_rpc_operation_receipts.group(:operation_id).count : {},
      },
      latestRun: {
        id: latest_run&.id,
        state: latest_run&.state,
        executionTargetId: latest_run&.execution_target_id,
        executionTargetName: latest_run&.execution_target&.name,
        deploymentFingerprint: latest_run&.deployment_fingerprint,
      },
      latestAgentNode: {
        id: latest_agent&.id,
        state: latest_agent&.state,
        outputText: latest_agent&.body&.output&.dig("content"),
        outputPreviewText: latest_agent&.body&.output_preview&.dig("content"),
      },
    })
  `)
}

export function bundledDefaultRuntimeState() {
  return railsJson<{
    programId: string
    programName: string
    deploymentId: string | null
    deploymentFingerprint: string | null
    deploymentStatus: string | null
    deploymentHealthStatus: string | null
    executionTargetId: string | null
    executionTargetName: string | null
  }>(`
    require "json"

    program = AgentPrograms::BootstrapBundledDefaultService.bootstrap!
    deployment = program.active_healthy_deployment
    target = ExecutionTarget.visible_for_runtime.order(:created_at).first

    puts JSON.generate({
      programId: program.id,
      programName: program.name,
      deploymentId: deployment&.id,
      deploymentFingerprint: deployment&.deployment_fingerprint,
      deploymentStatus: deployment&.status,
      deploymentHealthStatus: deployment&.health_status,
      executionTargetId: target&.id,
      executionTargetName: target&.name,
    })
  `)
}

export function ensureSingleBundledExecutionTarget() {
  return railsJson<{
    executionTargetId: string | null
    executionTargetName: string | null
  }>(`
    require "json"

    AgentPrograms::BootstrapBundledDefaultService.bootstrap!
    bundled_target =
      ExecutionTarget.find_by(name: "Bundled Default Target") ||
        ExecutionTarget.visible_for_runtime.order(:created_at).first

    if bundled_target.present?
      ExecutionTarget.where.not(id: bundled_target.id).update_all(status: "inactive", updated_at: Time.current)
      bundled_target.update!(status: "active") unless bundled_target.status == "active"
    end

    puts JSON.generate({
      executionTargetId: bundled_target&.id,
      executionTargetName: bundled_target&.name,
    })
  `)
}

export function agentProgramStateByName(name: string) {
  return railsJson<{
    programId: string
    programName: string
    selectable: boolean
    sourceKind: string
    bundledAgentKey: string | null
    forkedFromProgramId: string | null
    forkedFromProgramName: string | null
    activeDeploymentFingerprint: string | null
    activeDeploymentStatus: string | null
    activeDeploymentHealthStatus: string | null
  }>(`
    require "json"

    program = AgentProgram.find_by!(name: ${JSON.stringify(name)})
    deployment = program.active_healthy_deployment

    puts JSON.generate({
      programId: program.id,
      programName: program.name,
      selectable: program.selectable_for_conversation?,
      sourceKind: program.source_kind,
      bundledAgentKey: program.bundled_agent_key,
      forkedFromProgramId: program.forked_from_agent_program_id,
      forkedFromProgramName: program.forked_from_agent_program&.name,
      activeDeploymentFingerprint: deployment&.deployment_fingerprint,
      activeDeploymentStatus: deployment&.status,
      activeDeploymentHealthStatus: deployment&.health_status,
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

export async function openNewConversation(page: Page, title: string) {
  await page.goto("/conversations")
  await page.locator("main").getByPlaceholder("New conversation title").fill(title)
  await page.locator("main").getByRole("button", { name: "New" }).click()
  await expect(page).toHaveURL(/\/conversations\//)
}

export async function openConversationWithMockRuntime(page: Page, title: string) {
  await createHighPriorityMockProvider(page)
  await openNewConversation(page, title)
  await selectConversationRuntimeOption(page, "conversation-composer-execution-target-picker", "Bundled Default Target")
  // Execution target changes persist by reloading the page; select the ephemeral model override last.
  await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")
}

export function seedHotkeysFixtureConversation(title: string) {
  const markdown = "# Mock Markdown\n\n**Prompt:** please respond with markdown\n\n- This response is deterministic (for E2E).\n- It includes markdown constructs (heading, bold, list, code).\n\n`mock_llm streaming: enabled`"

  return railsJson<{ conversationId: string }>(`
    require "json"

    user = User.joins(:identity).find_by!(identities: { email: "admin@example.com" })
    program = AgentPrograms::BootstrapBundledDefaultService.ensure_program!
    target = ExecutionTarget.find_by(name: "Bundled Default Target") || ExecutionTarget.visible_for_runtime.order(:created_at).first

    Conversation.skip_callback(:commit, :after, :dispatch_bootstrap_hooks_after_commit)

    conversation =
      user.conversations.create!(
        title: ${JSON.stringify(title)},
        metadata: {
          "agent" => { "key" => "main", "agent_profile" => "coding" },
          "llm" => { "model_ref" => "dev/mock-model" },
        },
        agent_program: program,
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
        default_execution_target: target,
      )

    graph = conversation.dag_graph
    lane = conversation.chat_lane

    graph.mutate! do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "!md please respond with markdown",
          metadata: {},
        )

      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: ${JSON.stringify(markdown)},
          metadata: {},
        )

      m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    puts JSON.generate({ conversationId: conversation.id })
  `)
}

export async function openHotkeysFixtureConversation(page: Page, title: string) {
  await createHighPriorityMockProvider(page)
  const state = seedHotkeysFixtureConversation(title)
  await page.goto(`/conversations/${state.conversationId}`)
}

function conversationRuntimeOptionPersisted({
  conversationId,
  testId,
  label,
  expectedValue,
}: {
  conversationId: string
  testId: string
  label: string
  expectedValue: string | null
}) {
  const state = programmableConversationState(conversationId)

  switch (testId) {
    case "conversation-composer-model-picker":
      return state.selectedModelRef === expectedValue
    case "conversation-composer-agent-picker":
      return state.agentProgramName === label
    case "conversation-composer-permission-picker":
      return state.permissionMode === expectedValue
    case "conversation-composer-execution-target-picker":
      return state.defaultExecutionTargetName === (label === "No target selected" ? null : label)
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

  if (testId === "conversation-composer-model-picker") {
    await expect(locator).toHaveValue(expectedValue)
    return
  }

  const deadline = Date.now() + 15_000
  while (Date.now() < deadline) {
    if (conversationRuntimeOptionPersisted({ conversationId, testId, label, expectedValue })) {
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
