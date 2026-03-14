module Cybros
  module Agents
    module Claw
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
                "name" => @application.manifest.fetch("name")
              },
              "deployment" => {
                "key" => @application.identity.fetch("agent_deployment_key"),
                "fingerprint" => @application.identity.fetch("deployment_fingerprint")
              }
            }
          when "agent.describe"
            {
              "name" => @application.manifest.fetch("name"),
              "description" => @application.manifest.fetch("description"),
              "identity" => @application.identity
            }
          when "agent.health"
            {
              "healthy" => true,
              "status" => "healthy",
              "identity" => @application.identity
            }
          when "agent.schemas.get"
            {
              "global_config_schema" => @application.manifest.fetch("global_config_schema"),
              "conversation_config_schema" => @application.manifest.fetch("conversation_config_schema")
            }
          when "capabilities.handshake"
            cached_version = normalized_params.fetch("cached_agent_capabilities_version", "").to_s
            current_version = @application.agent_capabilities_version

            if cached_version == current_version
              {
                "status" => "unchanged",
                "agent_capabilities_version" => current_version
              }
            else
              {
                "status" => "refreshed",
                "agent_capabilities_version" => current_version,
                "agent_tool_catalog" => @application.agent_tool_catalog
              }
            end
          when "capabilities.refresh"
            {
              "status" => "refreshed",
              "refresh_reason" => normalized_params.fetch("reason", "").to_s,
              "agent_capabilities_version" => @application.agent_capabilities_version,
              "agent_tool_catalog" => @application.agent_tool_catalog
            }
          when "attachments.import"
            @application.import_attachments(params: normalized_params)
          when "on_conversation_created"
            Hooks::OnConversationCreated.new(application: @application).call(params: normalized_params)
          when "on_lane_first_user_message"
            Hooks::OnLaneFirstUserMessage.new(application: @application).call(params: normalized_params)
          when "before_agent_step"
            Hooks::BeforeAgentStep.new(application: @application).call(params: normalized_params)
          when "on_context_pressure"
            Hooks::OnContextPressure.new(application: @application).call(params: normalized_params)
          when "before_subagent_spawn"
            Hooks::BeforeSubagentSpawn.new(application: @application).call(params: normalized_params)
          when "before_finalize_output"
            Hooks::BeforeFinalizeOutput.new(application: @application).call(params: normalized_params)
          when "after_task_notice"
            Hooks::AfterTaskNotice.new(application: @application).call(params: normalized_params)
          when "after_subagent_result"
            Hooks::AfterSubagentResult.new(application: @application).call(params: normalized_params)
          else
            raise KeyError, "unsupported bundled claw RPC method: #{method_name}"
          end
        end
      end
    end
  end
end
