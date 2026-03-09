import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { type Locator, type Page, expect } from "@playwright/test"

const execFileAsync = promisify(execFile)

type SeededExecutionTargets = {
  primaryTargetId: string
  primaryTargetName: string
  alternateTargetId: string
  alternateTargetName: string
}

type SeededProgrammableRuntime = SeededExecutionTargets & {
  programId: string
  programName: string
  deploymentId: string
  deploymentFingerprint: string
}

export function rubyString(value: string) {
  return JSON.stringify(String(value))
}

export function programmableFixtureUrl() {
  const url = String(process.env.PROGRAMMABLE_AGENT_FIXTURE_URL || "").trim()
  if (!url) {
    throw new Error("PROGRAMMABLE_AGENT_FIXTURE_URL is required; run bin/ci_e2e with CI_E2E_PROGRAMMABLE_AGENT_FIXTURE=1")
  }

  return url
}

export async function railsJson<T>(ruby: string): Promise<T> {
  const { stdout } = await execFileAsync("bin/rails", ["runner", "-e", "development", ruby], {
    cwd: process.cwd(),
    env: process.env,
    maxBuffer: 10 * 1024 * 1024,
  })
  const lines = stdout.split("\n").map((line) => line.trim()).filter(Boolean)
  const payload = lines.at(-1)

  if (!payload) {
    throw new Error("rails runner did not emit JSON")
  }

  return JSON.parse(payload) as T
}

export function conversationIdFromUrl(url: string) {
  const match = url.match(/\/conversations\/([^/?#]+)/)
  if (!match) {
    throw new Error(`missing conversation id in URL: ${url}`)
  }

  return match[1]
}

export async function createConversation(page: Page, title: string) {
  await page.goto("/conversations")
  await page.locator("main").getByPlaceholder("New conversation title").fill(title)

  const navigation = page.waitForNavigation({ waitUntil: "domcontentloaded" }).catch(() => null)
  await page.locator("main").getByRole("button", { name: "New" }).click()
  await navigation

  await expect(page).toHaveURL(/\/conversations\//)
  return conversationIdFromUrl(page.url())
}

export async function selectComposerOption(page: Page, testId: string, label: string) {
  const navigation = page.waitForNavigation({ waitUntil: "domcontentloaded", timeout: 15_000 }).catch(() => null)
  await page.getByTestId(testId).selectOption({ label })
  await navigation
}

export function lastAgentMessage(page: Page) {
  return page.locator('div[id^="message_"]:has([data-role="agent-bubble"])').last()
}

export async function waitForAgentBubbleState(page: Page, expectedState: string, timeoutMs = 90_000): Promise<Locator> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const bubble = page.locator('[data-role="agent-bubble"]').last()
    const state = (await bubble.getAttribute("data-node-state").catch(() => "")) || ""
    if (state === expectedState) {
      return bubble
    }

    await page.waitForTimeout(750)
    await page.reload()
  }

  const bubble = page.locator('[data-role="agent-bubble"]').last()
  await expect(bubble).toHaveAttribute("data-node-state", expectedState)
  return bubble
}

export async function waitForAgentText(page: Page, text: string, timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const wrapper = lastAgentMessage(page)
    if ((await wrapper.count().catch(() => 0)) > 0) {
      const content = (await wrapper.textContent().catch(() => "")) || ""
      if (content.includes(text)) {
        return wrapper
      }
    }

    await page.waitForTimeout(750)
    await page.reload()
  }

  const wrapper = lastAgentMessage(page)
  await expect(wrapper).toContainText(text)
  return wrapper
}

export async function seedExecutionTargets(label: string): Promise<SeededExecutionTargets> {
  return railsJson<SeededExecutionTargets>(`
require "json"

label = ${rubyString(label)}

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

create_target = lambda do |name|
  location =
    ExecutionLocation.create!(
      name: "\#{name} host",
      kind: "host",
      platform: "macos_arm64",
      status: "active",
      trust_group: "operator",
      environment: "development",
      tags: ["e2e", label],
      max_concurrent_tasks: 4,
      max_queued_tasks: 16,
      default_timeout_s: 900,
    )
  workspace =
    Workspace.create!(
      execution_location: location,
      name: "\#{name} workspace",
      root_path: "/tmp/\#{name.downcase.gsub(/[^a-z0-9]+/, "-")}-\#{SecureRandom.hex(4)}",
      workspace_type: "git",
      status: "active",
      capability_tags: ["git"],
      tags: ["e2e", label],
    )

  ExecutionTarget.create!(
    execution_location: location,
    workspace: workspace,
    name: name,
    status: "active",
    sandboxed: true,
  )
end

primary = create_target.call("\#{label} Primary Target")
alternate = create_target.call("\#{label} Alternate Target")

puts JSON.generate(
  {
    primaryTargetId: primary.id,
    primaryTargetName: primary.name,
    alternateTargetId: alternate.id,
    alternateTargetName: alternate.name,
  },
)
`)
}

export async function seedActiveProgrammableRuntime(label: string): Promise<SeededProgrammableRuntime> {
  const fixtureUrl = programmableFixtureUrl()

  return railsJson<SeededProgrammableRuntime>(`
require "json"

label = ${rubyString(label)}
fixture_url = ${rubyString(fixtureUrl)}

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

create_target = lambda do |name|
  location =
    ExecutionLocation.create!(
      name: "\#{name} host",
      kind: "host",
      platform: "macos_arm64",
      status: "active",
      trust_group: "operator",
      environment: "development",
      tags: ["e2e", label],
      max_concurrent_tasks: 4,
      max_queued_tasks: 16,
      default_timeout_s: 900,
    )
  workspace =
    Workspace.create!(
      execution_location: location,
      name: "\#{name} workspace",
      root_path: "/tmp/\#{name.downcase.gsub(/[^a-z0-9]+/, "-")}-\#{SecureRandom.hex(4)}",
      workspace_type: "git",
      status: "active",
      capability_tags: ["git"],
      tags: ["e2e", label],
    )

  ExecutionTarget.create!(
    execution_location: location,
    workspace: workspace,
    name: name,
    status: "active",
    sandboxed: true,
  )
end

program =
  AgentProgram.create!(
    name: "\#{label} Program",
    config_namespace: "e2e.program.\#{SecureRandom.hex(4)}",
    published_contract_fingerprint: "contract:v1",
    manifest_snapshot: {
      "agent_program_key" => "fixture-program",
      "name" => "\#{label} Program",
    },
    global_config: {},
    global_config_schema: { "type" => "object" },
    conversation_config_schema: { "type" => "object" },
    config_schema_fingerprint: "config:v1",
  )

deployment =
  AgentDeployment.create!(
    agent_program: program,
    transport_kind: "http_jsonrpc",
    endpoint_url: fixture_url,
    deployment_bearer_secret_ref: "secret://fixture",
    contract_fingerprint: program.published_contract_fingerprint,
    deployment_fingerprint: "\#{label.downcase.gsub(/[^a-z0-9]+/, "-")}-deployment-v1",
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

primary = create_target.call("\#{label} Primary Target")
alternate = create_target.call("\#{label} Alternate Target")

puts JSON.generate(
  {
    programId: program.id,
    programName: program.name,
    deploymentId: deployment.id,
    deploymentFingerprint: deployment.deployment_fingerprint,
    primaryTargetId: primary.id,
    primaryTargetName: primary.name,
    alternateTargetId: alternate.id,
    alternateTargetName: alternate.name,
  },
)
`)
}

export async function deactivateDeployment(deploymentId: string) {
  await railsJson<{ ok: boolean }>(`
require "json"

deployment = AgentDeployment.find(${rubyString(deploymentId)})
deployment.update!(status: "inactive", health_status: "unhealthy", deactivated_at: Time.current.change(usec: 0))

puts JSON.generate({ ok: true })
`)
}

export async function deactivateExecutionTarget(executionTargetId: string) {
  await railsJson<{ ok: boolean }>(`
require "json"

execution_target = ExecutionTarget.find(${rubyString(executionTargetId)})
execution_target.update!(status: "inactive")

puts JSON.generate({ ok: true })
`)
}
