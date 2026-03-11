module AgentDeployments
  SUPPORTED_PROTOCOL_VERSION = "agent_rpc.v1".freeze
  REQUIRED_METHODS = %w[
    initialize
    agent.describe
    agent.health
    agent.schemas.get
    capabilities.handshake
    capabilities.refresh
    before_agent_step
    on_context_pressure
    before_subagent_spawn
    before_finalize_output
    after_task_notice
    after_subagent_result
  ].freeze

  class Error < StandardError; end
  class InspectionError < Error; end
  class IdentityMismatchError < InspectionError; end
  class ActivationError < Error; end
end
