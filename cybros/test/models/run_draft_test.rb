require "test_helper"

class RunDraftTest < ActiveSupport::TestCase
  test "stores recognized deployment bindings instead of mutable deployment and execution target state" do
    draft = RunDraft.new

    assert_equal :recognized_deployment, RunDraft.reflect_on_association(:recognized_deployment)&.name
    assert_nil RunDraft.reflect_on_association(:agent_deployment)
    assert_nil RunDraft.reflect_on_association(:proposed_execution_target)
    assert_includes RunDraft.attribute_names, "recognized_deployment_id"
    assert_includes RunDraft.attribute_names, "recognized_deployment_key"
    refute_respond_to draft, :agent_program
    refute_respond_to draft, :agent_deployment
    refute_respond_to draft, :proposed_execution_target
  end

  test "requires a conversation entrypoint" do
    draft = build_draft(conversation: nil)

    refute_predicate draft, :valid?
    assert_includes draft.errors[:conversation], "must exist"
  end

  test "persists planning envelopes and staged draft mutations with agent-scoped runtime governors" do
    runtime = create_runtime!
    draft = build_draft(runtime: runtime)

    assert_predicate draft, :valid?
    draft.save!

    assert_equal runtime.fetch(:agent).id, draft.agent_id
    assert_equal runtime.fetch(:recognized_deployment).id, draft.recognized_deployment_id
    assert_equal runtime.fetch(:recognized_deployment).recognized_deployment_key, draft.recognized_deployment_key
    assert_nil draft[:agent_program_id]
    assert_nil draft[:agent_deployment_id]
    assert_nil draft[:proposed_execution_target_id]
    assert_equal "default", draft.permission_mode
    assert_equal({ "kind" => "user_turn" }, draft.trigger_snapshot)
    assert_equal({ "steps" => ["draft"] }, draft.planning)
    assert_equal({ "title" => "Updated" }, draft.staged_public_settings_patch)
    assert_equal([{ "op" => "set", "key" => "shared.stage" }], draft.staged_kv_ops)
    assert_equal "config:v1", draft.agent_config_schema_fingerprint
    assert_equal runtime.fetch(:provider_credential).id, draft.runtime_governors.dig("provider_limiter", "provider_credential_id")
    assert_equal "agent", draft.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal runtime.fetch(:agent).id, draft.runtime_governors.dig("execution_capacity", "scope_id")
  end

  test "requires an agent config schema fingerprint snapshot" do
    draft = build_draft(agent_config_schema_fingerprint: nil)

    refute_predicate draft, :valid?
    assert_includes draft.errors[:agent_config_schema_fingerprint], "can't be blank"
  end

  test "bound_conversation only uses the explicit conversation association" do
    conversation = create_conversation!
    draft = build_draft(conversation: nil, trigger_snapshot: { "conversation_id" => conversation.id })

    assert_nil draft.bound_conversation
  end

  test "requires recognized deployments to belong to the selected agent" do
    runtime = create_runtime!
    other_runtime = create_runtime!(namespace: "fixture.other")

    draft =
      build_draft(
        runtime: runtime,
        recognized_deployment: other_runtime.fetch(:recognized_deployment),
        recognized_deployment_key: other_runtime.fetch(:recognized_deployment).recognized_deployment_key,
      )

    refute_predicate draft, :valid?
    assert_includes draft.errors[:recognized_deployment], "must belong to the selected agent"
  end

  test "requires runtime governor snapshots to match the selected provider and agent bindings" do
    runtime = create_runtime!
    draft =
      build_draft(
        runtime: runtime,
        runtime_governors: {
          "provider_limiter" => {
            "provider_key" => "anthropic",
            "provider_credential_id" => SecureRandom.uuid,
          },
          "execution_capacity" => {
            "scope_type" => "agent",
            "scope_id" => SecureRandom.uuid,
          },
        },
      )

    refute_predicate draft, :valid?
    assert_includes draft.errors[:runtime_governors], "must snapshot the selected provider credential"
    assert_includes draft.errors[:runtime_governors], "must snapshot the selected model provider"
    assert_includes draft.errors[:runtime_governors], "must snapshot the selected agent execution capacity policy"
  end

  test "snapshot accessors prefer persisted runtime ids over live recognized deployment pointers" do
    runtime = create_runtime!
    draft = build_draft(runtime: runtime)
    draft.save!
    original_deployment_fingerprint = draft.deployment_fingerprint
    replacement =
      create_deployment!(
        runtime.fetch(:program),
        deployment_fingerprint: "deployment:replacement",
        status: "inactive",
        health_status: "unknown",
      )

    runtime.fetch(:recognized_deployment).update!(deployment_fingerprint: replacement.deployment_fingerprint)

    assert_nil draft[:agent_program_id]
    assert_nil draft[:agent_deployment_id]
    assert_equal original_deployment_fingerprint, draft.deployment_fingerprint
  end

  test "keeps agent-scoped execution capacity snapshots without exposing execution target adapters" do
    runtime = create_runtime!
    draft =
      build_draft(
        runtime: runtime,
        runtime_governors: runtime_governors_snapshot(
          provider_credential: runtime.fetch(:provider_credential),
          selected_model_ref: "openai/gpt-5.4",
          agent: runtime.fetch(:agent),
        ),
      )

    assert_predicate draft, :valid?
    refute_respond_to draft, :proposed_execution_target
    assert_equal "agent", draft.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal runtime.fetch(:agent).id, draft.runtime_governors.dig("execution_capacity", "scope_id")
  end

  test "snapshots resolved governor facts from a conversation entrypoint without requiring a public execution target" do
    runtime = create_runtime!
    conversation = create_conversation!(agent: runtime.fetch(:agent), agent_program: runtime.fetch(:program), default_execution_target: nil)
    conversation.update!(permission_mode: "conservative")

    draft =
      build_draft(
        conversation: conversation,
        runtime: runtime,
        provider_credential: nil,
        runtime_governors: {},
        permission_mode: nil,
      )

    RuntimeGovernance::DraftGovernorResolver.apply!(
      draft: draft,
      entrypoint: conversation,
      selected_model_ref: "openai/gpt-5.4",
    )

    assert_equal "conservative", draft.permission_mode
    assert_equal runtime.fetch(:provider_credential), draft.provider_credential
    assert_equal conversation.agent, draft.agent
    refute_respond_to draft, :proposed_execution_target
    assert_nil draft[:proposed_execution_target_id]
    assert_equal "openai/gpt-5.4", draft.selected_model_ref
    assert_equal runtime.fetch(:provider_credential).id, draft.runtime_governors.dig("provider_limiter", "provider_credential_id")
    assert_equal "agent", draft.runtime_governors.dig("execution_capacity", "scope_type")
    assert_equal runtime.fetch(:agent).id, draft.runtime_governors.dig("execution_capacity", "scope_id")
  end

  private

    def build_draft(attributes = {})
      runtime = attributes.delete(:runtime) || create_runtime!
      conversation =
        if attributes.key?(:conversation)
          attributes.delete(:conversation)
        else
          create_conversation!(
            agent: runtime.fetch(:agent),
            agent_program: runtime.fetch(:program),
            default_execution_target: nil,
          )
        end
      provider_credential =
        if attributes.key?(:provider_credential)
          attributes.delete(:provider_credential)
        else
          runtime.fetch(:provider_credential)
        end
      recognized_deployment =
        if attributes.key?(:recognized_deployment)
          attributes.delete(:recognized_deployment)
        else
          runtime.fetch(:recognized_deployment)
        end
      recognized_deployment_key = attributes.delete(:recognized_deployment_key) || recognized_deployment&.recognized_deployment_key
      runtime_governors =
        if attributes.key?(:runtime_governors)
          attributes.delete(:runtime_governors)
        elsif provider_credential.present?
          runtime_governors_snapshot(
            provider_credential: provider_credential,
            selected_model_ref: "openai/gpt-5.4",
            agent: runtime.fetch(:agent),
          )
        else
          {}
        end

      RunDraft.new(
        {
          conversation: conversation,
          initiated_by_user: conversation&.user,
          status: "open",
          permission_mode: "default",
          trigger_snapshot: { "kind" => "user_turn" },
          agent: runtime.fetch(:agent),
          recognized_deployment: recognized_deployment,
          recognized_deployment_key: recognized_deployment_key,
          contract_fingerprint: runtime.fetch(:deployment).contract_fingerprint,
          deployment_fingerprint: runtime.fetch(:deployment).deployment_fingerprint,
          deployment_activated_at: runtime.fetch(:deployment).activated_at,
          agent_config_schema_fingerprint: runtime.fetch(:agent).config_schema_fingerprint,
          provider_credential: provider_credential,
          selected_model_ref: "openai/gpt-5.4",
          runtime_governors: runtime_governors,
          prepare_invocation_id: "prepare-1",
          planning: { "steps" => ["draft"] },
          staged_public_settings_patch: { "title" => "Updated" },
          staged_agent_config_patch: { "mode" => "coding" },
          staged_kv_ops: [{ "op" => "set", "key" => "shared.stage" }],
          staged_prompt_buffer_ops: [{
            "op" => "put",
            "entry" => {
              "id" => "entry-1",
              "buffer_name" => "summaries",
              "seq" => 10,
              "kind" => "summary",
              "content" => "Snapshot",
              "priority" => 2,
              "estimated_tokens" => 6,
              "metadata" => { "source" => "prepare" },
            },
          }],
          approval_state: { "status" => "not_required" },
          expires_at: 30.minutes.from_now.change(usec: 0),
        }.merge(attributes),
      )
    end

    def create_runtime!(namespace: "fixture.program")
      program =
        create_agent_record!(
          name: "Fixture Program #{SecureRandom.hex(4)}",
          config_namespace: "#{namespace}.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "name" => "Fixture", "agent_program_key" => "fixture-program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      target = create_execution_target!
      agent = materialize_agent_runtime!(program: program, execution_target: target)
      deployment = create_deployment!(program)
      recognized_deployment =
        Cybros::ProgrammableAgent::RecognizedDeploymentResolver.resolve!(
          agent: agent,
          deployment: deployment,
          initialize_result: {
            "identity" => {
              "agent_program_key" => program.manifest_snapshot["agent_program_key"],
              "deployment_fingerprint" => deployment.deployment_fingerprint,
              "protocol_version" => deployment.protocol_version,
              "agent_sdk_version" => deployment.agent_sdk_version,
              "supported_methods" => deployment.supported_methods,
            },
          },
          capability_snapshot: deployment.capability_snapshot,
        )
      provider_credential =
        ensure_llm_provider!(
          provider_key: "openai",
          credential_type: "api_key",
          status: "active",
          api_key: "sk-test",
        )

      {
        agent: agent,
        deployment: deployment,
        program: program,
        provider_credential: provider_credential,
        recognized_deployment: recognized_deployment,
        target: target,
      }
    end

    def create_deployment!(program, deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}", status: "active", health_status: "healthy")
      create_runtime_binding_record!(
        agent_program: program,
        transport_kind: "websocket",
        endpoint_url: "http://127.0.0.1:4319/rpc",
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        status: status,
        health_status: health_status,
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: { "agent_capabilities_version" => "2026-03-13" },
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_execution_target!(**attributes)
      location =
        create_execution_location_profile!(
          name: "Fixture host #{SecureRandom.hex(4)}",
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
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "Fixture workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/fixture-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )

      create_execution_profile!(
        {
          execution_location: location,
          workspace: workspace,
          name: "Fixture target #{SecureRandom.hex(4)}",
          status: "active",
          sandboxed: true,
        }.merge(attributes),
      )
    end
end
