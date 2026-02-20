# frozen_string_literal: true

Rails.application.config.to_prepare do
  AgentCore::DAG.runtime_resolver ||= lambda do |node:|
    _ = node

    provider =
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        base_url: ENV["SIMPLE_INFERENCE_BASE_URL"],
        api_key: ENV["SIMPLE_INFERENCE_API_KEY"],
      )

    tools_registry = AgentCore::Resources::Tools::Registry.new

    instrumenter =
      AgentCore::Observability::Adapters::ActiveSupportNotificationsInstrumenter.new

    AgentCore::DAG::Runtime.new(
      provider: provider,
      model: ENV.fetch("AGENT_CORE_MODEL", "gpt-4o-mini"),
      tools_registry: tools_registry,
      tool_policy: AgentCore::Resources::Tools::Policy::DenyAll.new,
      instrumenter: instrumenter,
    )
  end

  DAG::ExecutorRegistry

  DAG.executor_registry.register(
    Messages::AgentMessage.node_type_key,
    AgentCore::DAG::Executors::AgentMessageExecutor.new
  )

  DAG.executor_registry.register(
    Messages::CharacterMessage.node_type_key,
    AgentCore::DAG::Executors::AgentMessageExecutor.new
  )

  DAG.executor_registry.register(
    Messages::Task.node_type_key,
    AgentCore::DAG::Executors::TaskExecutor.new
  )
end
