module Cybros
  module Agents
    module Claw
      class Identity
        def initialize(manifest:, deployment_key:, deployment_fingerprint:)
          @manifest = manifest
          @deployment_key = deployment_key.to_s
          @deployment_fingerprint = deployment_fingerprint.to_s
        end

        def to_h
          {
            "agent_program_key" => @manifest.fetch("agent_program_key"),
            "agent_deployment_key" => @deployment_key,
            "deployment_fingerprint" => @deployment_fingerprint,
            "protocol_version" => @manifest.fetch("protocol_version"),
            "agent_sdk_version" => @manifest.fetch("agent_sdk_version"),
            "supported_methods" => @manifest.fetch("supported_methods")
          }
        end
      end
    end
  end
end
