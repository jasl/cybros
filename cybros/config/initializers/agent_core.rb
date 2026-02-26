Rails.application.config.to_prepare do
  AgentCore::DAG.runtime_resolver ||= lambda do |node:|
    Cybros::AgentRuntimeResolver.runtime_for(node: node)
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
