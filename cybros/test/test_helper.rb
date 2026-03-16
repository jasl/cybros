require "simplecov"
require "fileutils"

# Rails parallel tests can leave multiple named entries in `.resultset.json`.
# Clearing at the start avoids merging stale results across separate `bin/rails test`
# runs (e.g., when the worker count changes), which can otherwise skew coverage.
SimpleCov::ResultMerger.synchronize_resultset do
  FileUtils.mkdir_p(SimpleCov.coverage_path)
  File.write(SimpleCov::ResultMerger.resultset_path, "{}\n")
end

SimpleCov.enable_for_subprocesses true
SimpleCov.start "rails" do
  # Track coverage for app code only
  add_filter "/test/"
  add_filter "/config/"
  add_filter "/db/"
  add_filter "/vendor/"

  # Enforce overall coverage (evaluated on the final merged result) in CI.
  ci_enabled = ENV["CI"].to_s.strip != ""
  minimum_coverage(ci_enabled ? 85 : 0)
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "securerandom"

module RuntimeFixtureProfiles
  LocationProfile = Data.define(
    :id,
    :name,
    :kind,
    :platform,
    :status,
    :trust_group,
    :environment,
    :tags,
    :max_concurrent_tasks,
    :max_queued_tasks,
    :default_timeout_s,
  )

  WorkspaceProfile = Data.define(
    :id,
    :execution_location,
    :name,
    :root_path,
    :workspace_type,
    :status,
    :capability_tags,
    :tags,
  )

  ExecutionProfile = Data.define(
    :id,
    :execution_location,
    :workspace,
    :name,
    :status,
    :sandboxed,
    :max_concurrent_tasks_override,
    :max_queued_tasks_override,
    :default_timeout_s_override,
    :cpu_limit_millicores_override,
    :memory_limit_mb_override,
  ) do
    def max_concurrent_tasks
      max_concurrent_tasks_override || execution_location&.max_concurrent_tasks
    end

    def max_queued_tasks
      max_queued_tasks_override || execution_location&.max_queued_tasks
    end

    def default_timeout_s
      default_timeout_s_override || execution_location&.default_timeout_s
    end

    def cpu_limit_millicores
      cpu_limit_millicores_override
    end

    def memory_limit_mb
      memory_limit_mb_override
    end
  end
end

module ActiveSupport
  class TestCase
    # Rails parallel tests use Kernel.fork (not Process.fork), so SimpleCov's
    # enable_for_subprocesses doesn't automatically restart coverage in workers.
    # Hook into Rails' parallelization lifecycle to ensure each worker stores its
    # own result, then the parent process merges them at exit.
    if defined?(ActiveSupport::Testing::Parallelization)
      ActiveSupport::Testing::Parallelization.after_fork_hook do |_worker_id|
        next unless defined?(SimpleCov) && SimpleCov.running

        SimpleCov.at_fork.call(_worker_id)
      end
    end

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    setup do
      Account.instance.update_llm_default_model_ref!("dev/mock-model")
      Agents::BootstrapBundledDefaultService.ensure_test_runtime!
      ensure_llm_provider!(
        provider_key: "dev",
        credential_type: "api_key",
        status: "active",
        api_key: "sk-test",
        max_concurrent_requests: 3,
        requests_per_minute: 90,
        tokens_per_minute: 180_000,
        burst_limit: 6,
        backoff_policy: { "kind" => "exponential", "base_delay_ms" => 250, "max_delay_ms" => 10_000 },
      )
    end

    # Add more helper methods to be used by all tests here...

    def create_identity!(email: nil, password: "Passw0rd")
      email ||= "user-#{SecureRandom.hex(6)}@example.com"
      Identity.create!(
        email: email,
        password: password,
        password_confirmation: password,
      )
    end

    def create_user!(role: :owner, email: nil, password: "Passw0rd")
      identity = create_identity!(email: email, password: password)
      User.create!(identity: identity, role: role)
    end

    def with_default_agent_workspace_root(value)
      singleton = RuntimeSetting.singleton_class
      original_method = singleton.instance_method(:default_agent_workspace_root)
      existing_runtime_setting = RuntimeSetting.find_by(scope_key: "instance")
      original_runtime_attributes = existing_runtime_setting&.attributes&.slice("agent_workspace_root", "default_worker_concurrency", "queue_overrides", "alert_thresholds")

      singleton.send(:define_method, :default_agent_workspace_root) { value }
      if existing_runtime_setting.present?
        existing_runtime_setting.update_column(:agent_workspace_root, value)
      end
      yield
    ensure
      if original_runtime_attributes.present?
        RuntimeSetting.find_by(scope_key: "instance")&.update_columns(original_runtime_attributes)
      elsif existing_runtime_setting.nil?
        RuntimeSetting.where(scope_key: "instance").delete_all
      end
      singleton.send(:define_method, :default_agent_workspace_root, original_method)
    end

    def create_conversation!(user: nil, title: "Chat", metadata: nil, default_execution_target: :__default__, agent: :__default__, agent_program: :__default__)
      user ||= create_user!
      metadata ||= { "agent" => { "agent_profile" => "coding" } }
      if agent == :__default__
        agent = Agents::BootstrapBundledDefaultService.ensure_agent!
      end

      attributes = {
        user: user,
        title: title,
        metadata: metadata,
        agent: agent,
      }
      if agent.present?
        attributes[:agent_config_schema_fingerprint] = agent.config_schema_fingerprint
      end

      Conversation.create!(attributes)
    end

    def create_agent!(
      name: "Fixture Agent",
      config_namespace: "fixture.agent.#{SecureRandom.hex(4)}",
      published_contract_fingerprint: "contract:#{SecureRandom.hex(4)}",
      config_schema_fingerprint: "config:#{SecureRandom.hex(4)}",
      source_kind: "custom",
      bundled_agent_key: nil,
      local_path: nil,
      description: nil,
      manifest_snapshot: nil,
      global_config: {},
      global_config_schema: { "type" => "object" },
      conversation_config_schema: { "type" => "object" },
      args: {},
      max_concurrent_tasks: 4,
      max_queued_tasks: 16,
      default_timeout_s: 900,
      cpu_limit_millicores: nil,
      memory_limit_mb: nil,
      transport_kind: nil,
      endpoint_url: nil,
      deployment_bearer_secret_ref: nil,
      deployment_fingerprint: nil,
      status: "inactive",
      health_status: "unknown",
      protocol_version: nil,
      agent_sdk_version: nil,
      supported_methods: [],
      capability_snapshot: {},
      inspection_details: {},
      transport_config: {},
      activated_at: nil,
      deactivated_at: nil,
      last_health_checked_at: nil,
      last_inspected_at: nil
    )
      Agent.create!(
        name: name,
        description: description,
        source_kind: source_kind,
        bundled_agent_key: bundled_agent_key,
        local_path: source_kind == "custom" ? (local_path || "storage/agents/#{SecureRandom.hex(4)}") : local_path,
        config_namespace: config_namespace,
        published_contract_fingerprint: published_contract_fingerprint,
        manifest_snapshot: manifest_snapshot || { "name" => name },
        global_config: global_config,
        global_config_schema: global_config_schema,
        conversation_config_schema: conversation_config_schema,
        config_schema_fingerprint: config_schema_fingerprint,
        args: args,
        max_concurrent_tasks: max_concurrent_tasks,
        max_queued_tasks: max_queued_tasks,
        default_timeout_s: default_timeout_s,
        cpu_limit_millicores: cpu_limit_millicores,
        memory_limit_mb: memory_limit_mb,
        transport_kind: transport_kind,
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: deployment_bearer_secret_ref,
        deployment_fingerprint: deployment_fingerprint,
        status: status,
        health_status: health_status,
        protocol_version: protocol_version,
        agent_sdk_version: agent_sdk_version,
        supported_methods: supported_methods,
        capability_snapshot: capability_snapshot,
        inspection_details: inspection_details,
        transport_config: transport_config,
        activated_at: activated_at,
        deactivated_at: deactivated_at,
        last_health_checked_at: last_health_checked_at,
        last_inspected_at: last_inspected_at,
      )
    end

    def create_agent_record!(attributes = nil, **kwargs)
      attrs = normalize_fixture_attributes(attributes, kwargs)
      Agent.create!(
        name: attrs.fetch(:name, "Fixture Agent"),
        description: attrs[:description],
        source_kind: attrs.fetch(:source_kind, "custom"),
        bundled_agent_key: attrs[:bundled_agent_key],
        local_path:
          if attrs.fetch(:source_kind, "custom") == "custom"
            attrs[:local_path] || "storage/agents/#{SecureRandom.hex(4)}"
          else
            attrs[:local_path]
          end,
        config_namespace: attrs.fetch(:config_namespace, "fixture.agent.#{SecureRandom.hex(4)}"),
        published_contract_fingerprint: attrs.fetch(:published_contract_fingerprint, "contract:#{SecureRandom.hex(4)}"),
        manifest_snapshot: attrs[:manifest_snapshot] || { "name" => attrs.fetch(:name, "Fixture Agent") },
        global_config: attrs.fetch(:global_config, {}),
        global_config_schema: attrs.fetch(:global_config_schema, { "type" => "object" }),
        conversation_config_schema: attrs.fetch(:conversation_config_schema, { "type" => "object" }),
        config_schema_fingerprint: attrs.fetch(:config_schema_fingerprint, "config:#{SecureRandom.hex(4)}"),
        args: attrs.fetch(:args, {}),
        max_concurrent_tasks: attrs.fetch(:max_concurrent_tasks, 4),
        max_queued_tasks: attrs.fetch(:max_queued_tasks, 16),
        default_timeout_s: attrs.fetch(:default_timeout_s, 900),
        cpu_limit_millicores: attrs[:cpu_limit_millicores],
        memory_limit_mb: attrs[:memory_limit_mb],
        transport_kind: attrs[:transport_kind],
        endpoint_url: attrs[:endpoint_url],
        deployment_bearer_secret_ref: attrs[:deployment_bearer_secret_ref],
        deployment_fingerprint: attrs[:deployment_fingerprint],
        status: attrs.fetch(:status, "inactive"),
        health_status: attrs.fetch(:health_status, "unknown"),
        protocol_version: attrs[:protocol_version],
        agent_sdk_version: attrs[:agent_sdk_version],
        supported_methods: attrs.fetch(:supported_methods, []),
        capability_snapshot: attrs.fetch(:capability_snapshot, {}),
        inspection_details: attrs.fetch(:inspection_details, {}),
        transport_config: attrs.fetch(:transport_config, {}),
        activated_at: attrs[:activated_at],
        deactivated_at: attrs[:deactivated_at],
        last_health_checked_at: attrs[:last_health_checked_at],
        last_inspected_at: attrs[:last_inspected_at],
      )
    end

    def create_execution_location_profile!(attributes = nil, **kwargs)
      attrs = normalize_fixture_attributes(attributes, kwargs)
      RuntimeFixtureProfiles::LocationProfile.new(
        id: SecureRandom.uuid,
        name: attrs.fetch(:name, "Fixture host #{SecureRandom.hex(4)}"),
        kind: attrs.fetch(:kind, "host"),
        platform: attrs.fetch(:platform, "macos_arm64"),
        status: attrs.fetch(:status, "active"),
        trust_group: attrs.fetch(:trust_group, "operator"),
        environment: attrs.fetch(:environment, "development"),
        tags: attrs.fetch(:tags, ["fixture"]),
        max_concurrent_tasks: attrs.fetch(:max_concurrent_tasks, 4),
        max_queued_tasks: attrs.fetch(:max_queued_tasks, 16),
        default_timeout_s: attrs.fetch(:default_timeout_s, 900),
      )
    end

    def create_workspace_profile!(attributes = nil, **kwargs)
      attrs = normalize_fixture_attributes(attributes, kwargs)
      RuntimeFixtureProfiles::WorkspaceProfile.new(
        id: SecureRandom.uuid,
        execution_location: attrs.fetch(:execution_location),
        name: attrs.fetch(:name, "Fixture workspace #{SecureRandom.hex(4)}"),
        root_path: attrs.fetch(:root_path, "/tmp/fixture-#{SecureRandom.hex(4)}"),
        workspace_type: attrs.fetch(:workspace_type, "git"),
        status: attrs.fetch(:status, "active"),
        capability_tags: attrs.fetch(:capability_tags, ["git"]),
        tags: attrs.fetch(:tags, ["fixture"]),
      )
    end

    def create_execution_profile!(attributes = nil, **kwargs)
      attrs = normalize_fixture_attributes(attributes, kwargs)
      RuntimeFixtureProfiles::ExecutionProfile.new(
        id: SecureRandom.uuid,
        execution_location: attrs.fetch(:execution_location),
        workspace: attrs.fetch(:workspace),
        name: attrs.fetch(:name, "Fixture target #{SecureRandom.hex(4)}"),
        status: attrs.fetch(:status, "active"),
        sandboxed: attrs.fetch(:sandboxed, true),
        max_concurrent_tasks_override: attrs[:max_concurrent_tasks_override],
        max_queued_tasks_override: attrs[:max_queued_tasks_override],
        default_timeout_s_override: attrs[:default_timeout_s_override],
        cpu_limit_millicores_override: attrs[:cpu_limit_millicores_override],
        memory_limit_mb_override: attrs[:memory_limit_mb_override],
      )
    end

    def materialize_agent_runtime!(program:, execution_target: nil, deployment: nil)
      agent = program
      raise ArgumentError, "program must be an Agent" unless agent.is_a?(Agent)

      if execution_target.present?
        agent.assign_attributes(
          max_concurrent_tasks: execution_target.max_concurrent_tasks,
          max_queued_tasks: execution_target.max_queued_tasks,
          default_timeout_s: execution_target.default_timeout_s || Agent::DEFAULT_EXECUTION_TIMEOUT_S,
          cpu_limit_millicores: execution_target.cpu_limit_millicores,
          memory_limit_mb: execution_target.memory_limit_mb,
        )
      end

      agent.save! if agent.changed?
      sync_agent_runtime_from_binding!(agent: agent, deployment: deployment) if deployment.present?
      agent
    end

    def create_runtime_binding_record!(attributes = nil, agent_program: nil, agent: nil, **kwargs)
      attrs = normalize_fixture_attributes(attributes, kwargs)
      runtime_agent = agent || agent_program || attrs.delete(:agent_program) || attrs.delete(:agent)
      raise ArgumentError, "runtime binding requires an Agent" unless runtime_agent.is_a?(Agent)

      sync_agent_runtime_from_binding!(
        agent: runtime_agent,
        deployment: attrs.merge(agent: runtime_agent),
      )
    end

    def create_recognized_deployment!(
      agent:,
      deployment: nil,
      deployment_fingerprint: "deployment:#{SecureRandom.hex(4)}",
      contract_fingerprint: nil,
      protocol_version: "agent_rpc.v1",
      supported_methods: Agents::Protocol::REQUIRED_METHODS,
      capability_snapshot: {},
      agent_sdk_version: "fixture-ruby-sdk/1.0",
      agent_capabilities_version: nil,
      supports_upload: false,
      transport_kind: nil,
      endpoint_url: nil,
      deployment_bearer_secret_ref: nil,
      transport_config: nil
    )
      normalized_snapshot = capability_snapshot.is_a?(Hash) ? capability_snapshot.deep_stringify_keys : {}
      normalized_transport_config = transport_config.is_a?(Hash) ? transport_config.deep_stringify_keys : {}
      runtime_binding = deployment || agent
      payload = {
        "deployment_fingerprint" => deployment_fingerprint,
        "contract_fingerprint" => contract_fingerprint || agent.published_contract_fingerprint,
        "protocol_version" => protocol_version,
        "supported_methods" => Array(supported_methods).map(&:to_s).reject(&:blank?).sort,
        "agent_sdk_version" => agent_sdk_version,
        "agent_capabilities_version" => agent_capabilities_version || normalized_snapshot["agent_capabilities_version"],
        "capability_snapshot_digest" => RecognizedDeployment.digest_for(normalized_snapshot),
        "transport_kind" => transport_kind || runtime_binding.try(:transport_kind) || agent.transport_kind,
        "endpoint_url" => endpoint_url || runtime_binding.try(:endpoint_url) || agent.endpoint_url,
        "deployment_bearer_secret_ref" => deployment_bearer_secret_ref || runtime_binding.try(:deployment_bearer_secret_ref) || agent.deployment_bearer_secret_ref,
        "transport_config_digest" => normalized_transport_config.any? ? RecognizedDeployment.digest_for(normalized_transport_config) : nil,
      }.compact
      identity_digest = RecognizedDeployment.digest_for(payload)

      RecognizedDeployment.create!(
        agent: agent,
        identity_digest: identity_digest,
        recognized_deployment_key: "recognized_deployment:agent:#{agent.id}:#{identity_digest}",
        contract_fingerprint: contract_fingerprint || agent.published_contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        protocol_version: protocol_version,
        supported_methods: Array(supported_methods).map(&:to_s).reject(&:blank?),
        agent_sdk_version: agent_sdk_version,
        agent_capabilities_version: agent_capabilities_version || normalized_snapshot["agent_capabilities_version"],
        capability_snapshot_digest: payload["capability_snapshot_digest"],
        capability_snapshot: normalized_snapshot,
        supports_upload: supports_upload || Array(supported_methods).map(&:to_s).include?("attachments.import"),
      )
    end

    def sync_agent_runtime_from_binding!(agent:, deployment:)
      attributes =
        if deployment.is_a?(Hash)
          deployment.deep_symbolize_keys
        else
          {
            transport_kind: deployment.try(:transport_kind),
            endpoint_url: deployment.try(:endpoint_url),
            deployment_bearer_secret_ref: deployment.try(:deployment_bearer_secret_ref),
            deployment_fingerprint: deployment.try(:deployment_fingerprint),
            status: deployment.try(:status),
            health_status: deployment.try(:health_status),
            protocol_version: deployment.try(:protocol_version),
            agent_sdk_version: deployment.try(:agent_sdk_version),
            supported_methods: deployment.try(:supported_methods),
            capability_snapshot: deployment.try(:capability_snapshot),
            inspection_details: deployment.try(:inspection_details),
            transport_config: deployment.try(:transport_config),
            activated_at: deployment.try(:activated_at),
            deactivated_at: deployment.try(:deactivated_at),
            last_health_checked_at: deployment.try(:last_health_checked_at),
            last_inspected_at: deployment.try(:last_inspected_at),
          }
        end
      activated_at = attributes[:activated_at] || agent.activated_at || Time.current.change(usec: 0)
      agent.update!(
        transport_kind: attributes[:transport_kind],
        endpoint_url: attributes[:endpoint_url],
        deployment_bearer_secret_ref: attributes[:deployment_bearer_secret_ref],
        deployment_fingerprint: attributes[:deployment_fingerprint],
        status: attributes[:status].to_s.presence || "inactive",
        health_status: attributes[:health_status].to_s.presence || "unknown",
        protocol_version: attributes[:protocol_version],
        agent_sdk_version: attributes[:agent_sdk_version],
        supported_methods: Array(attributes[:supported_methods]).map(&:to_s),
        capability_snapshot: normalize_hash(attributes[:capability_snapshot]),
        inspection_details: normalize_hash(attributes[:inspection_details]),
        transport_config: normalize_hash(attributes[:transport_config]),
        activated_at: activated_at,
        deactivated_at: attributes[:deactivated_at],
        last_health_checked_at: attributes[:last_health_checked_at],
        last_inspected_at: attributes[:last_inspected_at],
      )
      agent
    end

    def create_agent_runtime!(program:, execution_target: nil, deployment: nil)
      materialize_agent_runtime!(program: program, execution_target: execution_target, deployment: deployment)
    end

    def recognize_agent_runtime!(agent:, deployment: nil, capability_snapshot: nil)
      if deployment.present?
        RecognizedDeployment.recognize!(
          agent: agent,
          deployment: deployment,
          capability_snapshot: capability_snapshot || deployment.try(:capability_snapshot),
        )
      else
        normalized_snapshot =
          if capability_snapshot.is_a?(Hash)
            capability_snapshot.deep_stringify_keys
          else
            agent.capability_snapshot
          end
        deployment_fingerprint = agent.deployment_fingerprint.presence || "deployment:#{SecureRandom.hex(4)}"
        protocol_version = agent.protocol_version.presence || "agent_rpc.v1"
        supported_methods = agent.supported_methods.presence || Agents::Protocol::REQUIRED_METHODS
        agent_sdk_version = agent.agent_sdk_version.presence || "fixture-ruby-sdk/1.0"
        identity_payload = {
          "deployment_fingerprint" => deployment_fingerprint,
          "contract_fingerprint" => agent.published_contract_fingerprint,
          "protocol_version" => protocol_version,
          "supported_methods" => Array(supported_methods).map(&:to_s).reject(&:blank?).sort,
          "agent_sdk_version" => agent_sdk_version,
          "agent_capabilities_version" => normalized_snapshot["agent_capabilities_version"],
          "capability_snapshot_digest" => RecognizedDeployment.digest_for(normalized_snapshot),
          "transport_kind" => agent.transport_kind,
          "endpoint_url" => agent.endpoint_url,
          "deployment_bearer_secret_ref" => agent.deployment_bearer_secret_ref,
          "transport_config_digest" => agent.transport_config.present? ? RecognizedDeployment.digest_for(agent.transport_config) : nil,
        }.compact
        identity_digest = RecognizedDeployment.digest_for(identity_payload)
        recognized_deployment_key = "recognized_deployment:agent:#{agent.id}:#{identity_digest}"

        RecognizedDeployment.find_by(recognized_deployment_key: recognized_deployment_key) ||
          create_recognized_deployment!(
            agent: agent,
            deployment: deployment,
            deployment_fingerprint: deployment_fingerprint,
            contract_fingerprint: agent.published_contract_fingerprint,
            protocol_version: protocol_version,
            supported_methods: supported_methods,
            capability_snapshot: normalized_snapshot,
            agent_sdk_version: agent_sdk_version,
            supports_upload: agent.supports_upload?,
          )
      end
    end

    def inspect_agent_runtime!(agent:)
      now = Time.current.change(usec: 0)
      Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: agent)
      agent.update!(
        status: "active",
        health_status: "healthy",
        activated_at: agent.activated_at || now,
        last_health_checked_at: now,
        last_inspected_at: now,
      )
      agent
    rescue StandardError => e
      agent.update!(
        status: "inactive",
        health_status: "unhealthy",
        inspection_details: agent.inspection_details.merge("error" => e.message),
        last_health_checked_at: now,
        last_inspected_at: now,
      )
      raise
    end

    def build_conversation_run_attributes(
      conversation:,
      dag_node_id:,
      agent:,
      recognized_deployment:,
      state: "queued",
      queued_at: Time.current.change(usec: 0),
      started_at: nil,
      finished_at: nil,
      initiated_by_user: nil,
      effective_permission_mode: "default",
      provider_credential: nil,
      selected_model_ref: nil,
      effective_public_settings: {},
      effective_agent_config: {},
      agent_config_schema_fingerprint: nil,
      effective_policy: {},
      runtime_governors: nil,
      snapshot: {},
      error: nil
    )
      default_runtime_governors =
        runtime_governors_snapshot(
          provider_credential: provider_credential,
          selected_model_ref: selected_model_ref,
          agent: agent,
        )
      resolved_runtime_governors =
        if runtime_governors.present?
          default_runtime_governors.deep_merge(runtime_governors.deep_stringify_keys)
        else
          default_runtime_governors
        end

      {
        conversation: conversation,
        dag_node_id: dag_node_id,
        state: state,
        queued_at: queued_at,
        started_at: started_at,
        finished_at: finished_at,
        initiated_by_user: initiated_by_user || conversation.user,
        snapshot_version: 1,
        effective_permission_mode: effective_permission_mode,
        agent: agent,
        recognized_deployment: recognized_deployment,
        recognized_deployment_key: recognized_deployment.recognized_deployment_key,
        contract_fingerprint: recognized_deployment.contract_fingerprint,
        deployment_fingerprint: recognized_deployment.deployment_fingerprint,
        deployment_activated_at: agent.activated_at || queued_at,
        provider_credential: provider_credential,
        selected_model_ref: selected_model_ref,
        effective_public_settings: effective_public_settings,
        effective_agent_config: effective_agent_config,
        agent_config_schema_fingerprint: agent_config_schema_fingerprint || agent.config_schema_fingerprint,
        effective_policy: effective_policy,
        runtime_governors: resolved_runtime_governors,
        snapshot: snapshot,
        error: error,
      }.compact
    end

    def create_conversation_run!(
      conversation:,
      dag_node_id:,
      agent:,
      recognized_deployment:,
      **attributes
    )
      ConversationRun.create!(
        build_conversation_run_attributes(
          conversation: conversation,
          dag_node_id: dag_node_id,
          agent: agent,
          recognized_deployment: recognized_deployment,
          **attributes,
        ),
      )
    end

    def build_run_draft_attributes(
      conversation:,
      agent:,
      recognized_deployment:,
      status: "prepared",
      initiated_by_user: nil,
      permission_mode: "default",
      trigger_snapshot:,
      contract_fingerprint: recognized_deployment.contract_fingerprint,
      deployment_fingerprint: recognized_deployment.deployment_fingerprint,
      deployment_activated_at: agent.activated_at || Time.current.change(usec: 0),
      provider_credential: nil,
      selected_model_ref: nil,
      runtime_governors: nil,
      agent_config_schema_fingerprint: nil,
      prepare_invocation_id: SecureRandom.uuid,
      planning: {},
      staged_public_settings_patch: {},
      staged_agent_config_patch: {},
      staged_kv_ops: [],
      staged_prompt_buffer_ops: [],
      approval_state: { "status" => "not_required" },
      expires_at: 30.minutes.from_now.change(usec: 0),
      materialized_conversation_run: nil
    )
      default_runtime_governors =
        runtime_governors_snapshot(
          provider_credential: provider_credential,
          selected_model_ref: selected_model_ref,
          agent: agent,
        )
      resolved_runtime_governors =
        if runtime_governors.present?
          default_runtime_governors.deep_merge(runtime_governors.deep_stringify_keys)
        else
          default_runtime_governors
        end

      {
        conversation: conversation,
        initiated_by_user: initiated_by_user || conversation.user,
        status: status,
        permission_mode: permission_mode,
        trigger_snapshot: trigger_snapshot,
        agent: agent,
        recognized_deployment: recognized_deployment,
        recognized_deployment_key: recognized_deployment.recognized_deployment_key,
        contract_fingerprint: contract_fingerprint,
        deployment_fingerprint: deployment_fingerprint,
        deployment_activated_at: deployment_activated_at,
        provider_credential: provider_credential,
        selected_model_ref: selected_model_ref,
        runtime_governors: resolved_runtime_governors,
        agent_config_schema_fingerprint: agent_config_schema_fingerprint || agent.config_schema_fingerprint,
        prepare_invocation_id: prepare_invocation_id,
        planning: planning,
        staged_public_settings_patch: staged_public_settings_patch,
        staged_agent_config_patch: staged_agent_config_patch,
        staged_kv_ops: staged_kv_ops,
        staged_prompt_buffer_ops: staged_prompt_buffer_ops,
        approval_state: approval_state,
        expires_at: expires_at,
        materialized_conversation_run: materialized_conversation_run,
      }.compact
    end

    def create_run_draft!(
      conversation:,
      agent:,
      recognized_deployment:,
      **attributes
    )
      RunDraft.create!(
        build_run_draft_attributes(
          conversation: conversation,
          agent: agent,
          recognized_deployment: recognized_deployment,
          **attributes,
        ),
      )
    end

    def runtime_governors_snapshot(provider_credential: nil, selected_model_ref: nil, execution_target: nil, agent: nil)
      {}.tap do |snapshot|
        provider_snapshot = provider_limiter_snapshot(provider_credential: provider_credential, selected_model_ref: selected_model_ref)
        snapshot["provider_limiter"] = provider_snapshot if provider_snapshot.any?
        snapshot["execution_capacity"] = RuntimeGovernance::ExecutionCapacityResolver.resolve!(agent: agent) if agent.present?
      end
    end

    def provider_limiter_snapshot(provider_credential: nil, selected_model_ref: nil)
      {}.tap do |snapshot|
        provider_key = selected_model_ref.to_s.split("/", 2).first.to_s
        snapshot["provider_key"] = provider_key if provider_key.present?
        snapshot["provider_credential_id"] = provider_credential.id if provider_credential.present?
      end
    end

    def build_default_execution_profile!
      location =
        create_execution_location_profile!(
          name: "Default test host",
          environment: "test",
          tags: ["fixture"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "Default test workspace",
          root_path: "/tmp/cybros-default-test-workspace",
          capability_tags: ["git", "shell"],
          tags: ["fixture"],
        )

      create_execution_profile!(
        execution_location: location,
        workspace: workspace,
        name: "Default test target",
        status: "active",
        sandboxed: true,
      )
    end

    def ensure_llm_provider!(provider_key:, credential_type:, **attributes)
      attrs = { credential_type: credential_type }.merge(attributes)

      provider = LLMProviderCredential.find_or_initialize_by(provider_key: provider_key)
      provider.assign_attributes(attrs)
      provider.save!
      provider
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      provider = LLMProviderCredential.find_by!(provider_key: provider_key)
      provider.update!(attrs)
      provider
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def normalize_fixture_attributes(attributes, kwargs)
      base = attributes.is_a?(Hash) ? attributes.deep_symbolize_keys : {}
      base.merge(kwargs)
    end
  end
end
