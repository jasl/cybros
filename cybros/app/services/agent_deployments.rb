module AgentDeployments
  SUPPORTED_PROTOCOL_VERSION = "agent_rpc.v1".freeze
  REQUIRED_METHODS = %w[
    initialize
    agent.describe
    agent.health
    agent.schemas.get
    turn.prepare
    turn.compose
  ].freeze

  class Error < StandardError; end
  class InspectionError < Error; end
  class IdentityMismatchError < InspectionError; end
  class ActivationError < Error; end
end
