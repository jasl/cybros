# frozen_string_literal: true

module AgentCore
  module DAG
    class << self
      attr_accessor :runtime_resolver
    end

    def self.runtime_for(node:)
      resolver = runtime_resolver

      unless resolver.respond_to?(:call)
        raise AgentCore::ConfigurationError,
              "AgentCore::DAG.runtime_resolver is not set (expected a callable returning AgentCore::DAG::Runtime)"
      end

      runtime = resolver.call(node: node)

      if runtime.is_a?(Runtime)
        runtime
      else
        raise AgentCore::ConfigurationError,
              "AgentCore::DAG.runtime_resolver must return AgentCore::DAG::Runtime (got #{runtime.class})"
      end
    end
  end
end
