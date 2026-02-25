# frozen_string_literal: true

module AgentCore
  module DAG
    class << self
      attr_accessor :runtime_resolver
    end

    def self.runtime_for(node:)
      resolver = runtime_resolver

      unless resolver.respond_to?(:call)
        AgentCore::ConfigurationError.raise!(
          "AgentCore::DAG.runtime_resolver is not set (expected a callable returning AgentCore::DAG::Runtime)",
          code: "agent_core.dag.agentcore_dag_runtime_resolver_is_not_set_expected_a_callable_returning_agentcore_dag_runtime",
        )
      end

      runtime = resolver.call(node: node)

      if runtime.is_a?(Runtime)
        runtime
      else
        AgentCore::ConfigurationError.raise!(
          "AgentCore::DAG.runtime_resolver must return AgentCore::DAG::Runtime (got #{runtime.class})",
          code: "agent_core.dag.agentcore_dag_runtime_resolver_must_return_agentcore_dag_runtime_got",
          details: { runtime_class: runtime.class.name },
        )
      end
    end
  end
end
