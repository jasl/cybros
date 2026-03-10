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
      AgentPrograms::BootstrapBundledDefaultService.ensure_test_runtime!
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

    def create_conversation!(user: nil, title: "Chat", metadata: nil, default_execution_target: :__default__, agent_program: :__default__)
      user ||= create_user!
      metadata ||= { "agent" => { "agent_profile" => "coding" } }
      if default_execution_target == :__default__
        default_execution_target = ensure_default_execution_target!
      end

      if agent_program == :__default__
        agent_program = AgentPrograms::BootstrapBundledDefaultService.ensure_program!
      end

      attributes = {
        user: user,
        title: title,
        metadata: metadata,
        default_execution_target: default_execution_target,
      }
      if agent_program.present?
        attributes[:agent_program] = agent_program
        attributes[:agent_config_schema_fingerprint] = agent_program.config_schema_fingerprint
      end

      Conversation.create!(attributes)
    end

    def runtime_governors_snapshot(provider_credential: nil, selected_model_ref: nil, execution_target: nil)
      {}.tap do |snapshot|
        provider_snapshot = provider_limiter_snapshot(provider_credential: provider_credential, selected_model_ref: selected_model_ref)
        snapshot["provider_limiter"] = provider_snapshot if provider_snapshot.any?
        if execution_target.present?
          snapshot["execution_capacity"] = RuntimeGovernance::ExecutionCapacityResolver.resolve!(execution_target: execution_target)
        end
      end
    end

    def provider_limiter_snapshot(provider_credential: nil, selected_model_ref: nil)
      {}.tap do |snapshot|
        provider_key = selected_model_ref.to_s.split("/", 2).first.to_s
        snapshot["provider_key"] = provider_key if provider_key.present?
        snapshot["provider_credential_id"] = provider_credential.id if provider_credential.present?
      end
    end

    def ensure_default_execution_target!
      location =
        ExecutionLocation.find_or_create_by!(name: "Default test host") do |record|
          record.kind = "host"
          record.platform = "macos_arm64"
          record.status = "active"
          record.trust_group = "operator"
          record.environment = "test"
          record.tags = ["fixture"]
          record.max_concurrent_tasks = 4
          record.max_queued_tasks = 16
          record.default_timeout_s = 900
        end
      workspace =
        Workspace.find_or_create_by!(execution_location: location, name: "Default test workspace") do |record|
          record.root_path = "/tmp/cybros-default-test-workspace"
          record.workspace_type = "git"
          record.status = "active"
          record.capability_tags = ["git", "shell"]
          record.tags = ["fixture"]
        end

      ExecutionTarget.find_or_create_by!(execution_location: location, workspace: workspace, name: "Default test target") do |record|
        record.status = "active"
        record.sandboxed = true
      end
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
  end
end
