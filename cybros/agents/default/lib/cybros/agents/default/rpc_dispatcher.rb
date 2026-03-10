module Cybros
  module Agents
    module Default
      class RPCDispatcher
        def initialize(application:)
          @application = application
        end

        def dispatch(method_name:, params:)
          normalized_params = params.is_a?(Hash) ? Manifest.deep_stringify(params) : {}

          case method_name.to_s
          when "initialize"
            {
              "identity" => @application.identity,
              "agent" => {
                "key" => @application.manifest.fetch("agent_program_key"),
                "name" => @application.manifest.fetch("name"),
              },
              "deployment" => {
                "key" => @application.identity.fetch("agent_deployment_key"),
                "fingerprint" => @application.identity.fetch("deployment_fingerprint"),
              },
            }
          when "agent.describe"
            {
              "name" => @application.manifest.fetch("name"),
              "description" => @application.manifest.fetch("description"),
              "identity" => @application.identity,
            }
          when "agent.health"
            {
              "healthy" => true,
              "status" => "healthy",
              "identity" => @application.identity,
            }
          when "agent.schemas.get"
            {
              "global_config_schema" => @application.manifest.fetch("global_config_schema"),
              "conversation_config_schema" => @application.manifest.fetch("conversation_config_schema"),
            }
          when "turn.prepare"
            Hooks::Prepare.new(application: @application).call(params: normalized_params)
          when "turn.compose"
            Hooks::Compose.new(application: @application).call(params: normalized_params)
          when "turn.handle_error"
            Hooks::HandleError.new(application: @application).call(params: normalized_params)
          else
            raise KeyError, "unsupported bundled default RPC method: #{method_name}"
          end
        end
      end
    end
  end
end
