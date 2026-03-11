require "json"

module AgentCore
  module DAG
    module Executors
      class TaskExecutor
        DEFAULT_MAX_RESULT_BYTES = AgentCore::Utils::DEFAULT_MAX_TOOL_OUTPUT_BYTES
        ProgrammableToolRoute =
          Data.define(
            :logical_tool_name,
            :effective_tool_id,
            :implementation_source,
            :implementation_ref,
            :capability_registry_snapshot_id,
            :tool_surface_id,
          )

        def execute(node:, context:, stream:)
          runtime = AgentCore::DAG.runtime_for(node: node)
          execution_context = ExecutionContextBuilder.build(node: node, runtime: runtime)
          tool_route = programmable_tool_route_from_input(node)

          tool_name, arguments = tool_call_from_input(node, tool_route: tool_route)
          preflight_result = run_before_subagent_spawn_hook!(runtime: runtime, node: node, tool_name: tool_name, arguments: arguments)
          return preflight_result if preflight_result

          activity_id = "task:#{node.id}"
          activity_kind = activity_kind_for(node, tool_name: tool_name)
          activity_phase = activity_phase_for(activity_kind: activity_kind)

          stream&.activity_started!(
            activity_id: activity_id,
            activity_kind: activity_kind,
            phase: activity_phase,
            source_node_id: node.id,
            diagnostic_level: diagnostic_level_for(node),
          )

          result =
            execution_context.instrumenter.instrument(
              "agent_core.tool.execute",
              run_id: execution_context.run_id,
              tool: tool_name,
              provider: runtime_name(runtime),
            ) do
              execute_tool_call(
                runtime: runtime,
                node: node,
                execution_context: execution_context,
                tool_name: tool_name,
                arguments: arguments,
                tool_route: tool_route,
              )
            end

          result = truncate_raw_result(result)
          run_after_subagent_result_hook!(runtime: runtime, node: node, tool_name: tool_name, result: result)
          projection =
            AgentCore::RuntimeSurface::ToolResultProjection.new(
              runtime: runtime,
              execution_context: execution_context,
              tool_call: {
                id: node.body_input["tool_call_id"],
                name: tool_name,
                arguments: arguments,
              },
              context: context,
            ).call(raw_result: result)

          if result.error?
            stream&.activity_failed!(
              activity_id: activity_id,
              activity_kind: activity_kind,
              phase: activity_phase,
              source_node_id: node.id,
              diagnostic_level: diagnostic_level_for(node),
              data: { "error" => projection.activity_preview.to_s },
            )
          else
            stream&.activity_finished!(
              activity_id: activity_id,
              activity_kind: activity_kind,
              phase: activity_phase,
              source_node_id: node.id,
              diagnostic_level: diagnostic_level_for(node),
            )
          end

          ::DAG::ExecutionResult.finished(
            payload: projection.payload,
            metadata: {
              "tool" => build_tool_metadata(tool_name: tool_name, tool_route: tool_route),
              "agent" => AgentCore::Utils.deep_stringify_keys(execution_context.attributes.fetch(:agent, {})),
            },
          )
        rescue AgentCore::ToolNotFoundError => e
          stream&.activity_failed!(
            activity_id: "task:#{node.id}",
            activity_kind: activity_kind_for(node, tool_name: tool_call_name_from_input(node)),
            phase: activity_phase_for(activity_kind: activity_kind_for(node, tool_name: tool_call_name_from_input(node))),
            source_node_id: node.id,
            diagnostic_level: diagnostic_level_for(node),
            data: { "error" => "ToolNotFoundError: #{e.message}" },
          )
          ::DAG::ExecutionResult.errored(error: "ToolNotFoundError: #{e.message}")
        rescue AgentCore::ValidationError => e
          raise if fail_fast_programmable_error?(e)

          stream&.activity_failed!(
            activity_id: "task:#{node.id}",
            activity_kind: activity_kind_for(node, tool_name: tool_call_name_from_input(node)),
            phase: activity_phase_for(activity_kind: activity_kind_for(node, tool_name: tool_call_name_from_input(node))),
            source_node_id: node.id,
            diagnostic_level: diagnostic_level_for(node),
            data: { "error" => "#{e.class}: #{e.message}" },
          )
          ::DAG::ExecutionResult.errored(error: "#{e.class}: #{e.message}")
        rescue StandardError => e
          stream&.activity_failed!(
            activity_id: "task:#{node.id}",
            activity_kind: activity_kind_for(node, tool_name: tool_call_name_from_input(node)),
            phase: activity_phase_for(activity_kind: activity_kind_for(node, tool_name: tool_call_name_from_input(node))),
            source_node_id: node.id,
            diagnostic_level: diagnostic_level_for(node),
            data: { "error" => "#{e.class}: #{e.message}" },
          )
          ::DAG::ExecutionResult.errored(error: "#{e.class}: #{e.message}")
        end

        private

          def activity_kind_for(node, tool_name:)
            if tool_name.to_s == "compress_input"
              "preflight_task"
            else
              "tool_call"
            end
          end

          def activity_phase_for(activity_kind:)
            activity_kind == "preflight_task" ? "preflight" : "execution"
          end

          def tool_call_name_from_input(node)
            input = node.body_input.is_a?(Hash) ? node.body_input : {}
            route = programmable_tool_route_from_input(node, strict: false)
            route&.logical_tool_name.to_s.presence || input.fetch("name", input.fetch("requested_name", "")).to_s
          end

          def diagnostic_level_for(node)
            agent =
              node.graph.nodes.active
                .where(lane_id: node.lane_id, turn_id: node.turn_id, node_type: %w[agent_message character_message])
                .order(:id)
                .last

            level =
              if agent&.metadata.is_a?(Hash)
                agent.metadata.dig("turn_execution", "diagnostic_level")
              end

            level.to_s == "debug" ? "debug" : "standard"
          rescue StandardError
            "standard"
          end

          def tool_call_from_input(node, tool_route: nil)
            input = node.body_input.is_a?(Hash) ? node.body_input : {}
            tool_name = tool_route&.logical_tool_name.to_s
            tool_name = input.fetch("name", "").to_s if tool_name.strip.empty?
            tool_name = input.fetch("requested_name", "").to_s if tool_name.strip.empty?

            ValidationError.raise!(
              "task.name is required",
              code: "agent_core.dag.task_executor.task_name_is_required",
            ) if tool_name.strip.empty?

            args = input.fetch("arguments", {})
            args = {} unless args.is_a?(Hash)
            [tool_name, AgentCore::Utils.deep_stringify_keys(args)]
          end

          def execute_tool_call(runtime:, node:, execution_context:, tool_name:, arguments:, tool_route:)
            if tool_route&.implementation_source == "agent_program"
              payload =
                programmable_tool_executor_for(runtime).execute_programmable_tool!(
                  tool_call_id: node.body_input.fetch("tool_call_id", ""),
                  logical_tool_name: tool_route.logical_tool_name,
                  effective_tool_id: tool_route.effective_tool_id,
                  implementation_ref: tool_route.implementation_ref,
                  capability_registry_snapshot_id: tool_route.capability_registry_snapshot_id,
                  tool_surface_id: tool_route.tool_surface_id,
                  arguments: arguments,
                )
              result_payload = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
              result = result_payload["result"]

              ValidationError.raise!(
                "tool.execute must return a result payload",
                code: "cybros.programmable_agent.tool_execute.result_is_required",
              ) unless result.is_a?(Hash)

              AgentCore::Resources::Tools::ToolResult.from_h(result)
            else
              runtime.tools_registry.execute(
                name: tool_name,
                arguments: arguments,
                context: execution_context,
                tool_error_mode: runtime.tool_error_mode
              )
            end
          end

          def build_tool_metadata(tool_name:, tool_route:)
            metadata = { "name" => tool_name }
            return metadata unless tool_route

            metadata.merge(
              "logical_tool_name" => tool_route.logical_tool_name,
              "effective_tool_id" => tool_route.effective_tool_id,
              "implementation_source" => tool_route.implementation_source,
              "implementation_ref" => tool_route.implementation_ref,
              "capability_registry_snapshot_id" => tool_route.capability_registry_snapshot_id,
              "tool_surface_id" => tool_route.tool_surface_id,
            )
          end

          def programmable_tool_executor_for(runtime)
            provider = runtime.provider
            return provider if provider.respond_to?(:execute_programmable_tool!)

            ValidationError.raise!(
              "runtime provider does not support agent_program tool execution",
              code: "agent_core.dag.task_executor.programmable_tool_executor_missing",
              details: {
                provider_class: provider.class.name,
                provider_name: runtime_name(runtime),
              },
            )
          end

          def run_after_subagent_result_hook!(runtime:, node:, tool_name:, result:)
            return unless tool_name.to_s == "subagent_wait"

            provider = programmable_hook_provider_for(runtime, method_name: :run_after_subagent_result!)
            return unless provider

            payload = subagent_result_hook_payload(result)
            return if payload.nil?

            provider.run_after_subagent_result!(
              node: node,
              subagent_result: payload,
            )
          end

          def run_before_subagent_spawn_hook!(runtime:, node:, tool_name:, arguments:)
            return nil unless spawn_family_tool?(tool_name)

            provider = programmable_hook_provider_for(runtime, method_name: :run_before_subagent_spawn!)
            return nil unless provider

            outcome =
              provider.run_before_subagent_spawn!(
                node: node,
                subagent_request: {
                  "tool_name" => tool_name.to_s,
                  "tool_call_id" => node.body_input.fetch("tool_call_id", "").to_s,
                  "arguments" => AgentCore::Utils.deep_stringify_keys(arguments),
                },
              )

            task_result_from_hook_outcome(outcome)
          end

          def subagent_result_hook_payload(result)
            return nil unless result.respond_to?(:metadata) && result.metadata.is_a?(Hash)

            metadata = AgentCore::Utils.deep_stringify_keys(result.metadata)
            subagent = metadata["subagent"]
            return nil unless subagent.is_a?(Hash) && subagent["subagent_id"].to_s.present?

            {
              "status" => result.error? ? "failed" : "succeeded",
              "subagent_id" => subagent["subagent_id"].to_s,
              "result" => result.respond_to?(:to_h) ? AgentCore::Utils.deep_stringify_keys(result.to_h) : {},
              "artifacts" => Array(subagent["artifacts"]).presence,
              "assistant_output_candidate" => AgentCore::Utils.deep_stringify_keys(subagent["assistant_output_candidate"]),
            }.compact
          end

          def programmable_hook_provider_for(runtime, method_name:)
            provider = runtime.provider
            return provider if provider.respond_to?(method_name)

            nil
          rescue StandardError
            nil
          end

          def task_result_from_hook_outcome(outcome)
            return nil unless outcome

            if outcome.respond_to?(:deferred_anchor) && outcome.deferred_anchor
              return ::DAG::ExecutionResult.stopped(
                reason: "deferred_by_hook",
                metadata: {
                  "hook_name" => "before_subagent_spawn",
                  "action_type" => "create_task",
                  "placement" => "prepend",
                },
              )
            end

            terminal_action = outcome.respond_to?(:terminal_action) ? outcome.terminal_action : nil
            return nil unless terminal_action

            metadata = {
              "hook_name" => "before_subagent_spawn",
              "action_type" => terminal_action.type,
            }
            metadata["message"] = terminal_action.message if terminal_action.message.present?

            case terminal_action.type
            when "deny"
              ::DAG::ExecutionResult.rejected(
                reason: terminal_action.reason.presence || "denied_by_hook",
                metadata: metadata,
              )
            when "halt"
              ::DAG::ExecutionResult.stopped(
                reason: terminal_action.reason.presence || "halted_by_hook",
                metadata: metadata,
              )
            else
              nil
            end
          end

          def spawn_family_tool?(tool_name)
            %w[subagent_spawn subagent_run].include?(tool_name.to_s)
          end

          def fail_fast_programmable_error?(error)
            return false unless error.is_a?(AgentCore::ValidationError)

            code = error.code.to_s
            code.start_with?("cybros.programmable_agent.", "cybros.agent_rpc.")
          rescue StandardError
            false
          end

          def programmable_tool_route_from_input(node, strict: true)
            input = node.body_input.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(node.body_input) : {}
            implementation_source = input["implementation_source"].to_s
            return nil if implementation_source.blank?

            route =
              ProgrammableToolRoute.new(
                logical_tool_name: input["logical_tool_name"].to_s,
                effective_tool_id: input["effective_tool_id"].to_s,
                implementation_source: implementation_source,
                implementation_ref: input["implementation_ref"].to_s,
                capability_registry_snapshot_id: input["capability_registry_snapshot_id"].to_s,
                tool_surface_id: input["tool_surface_id"].to_s,
              )

            missing =
              {
                "logical_tool_name" => route.logical_tool_name,
                "effective_tool_id" => route.effective_tool_id,
                "implementation_ref" => route.implementation_ref,
                "capability_registry_snapshot_id" => route.capability_registry_snapshot_id,
                "tool_surface_id" => route.tool_surface_id,
              }.select { |_key, value| value.blank? }.keys

            if missing.any?
              return nil unless strict

              ValidationError.raise!(
                "programmable tool routing metadata is incomplete",
                code: "agent_core.dag.task_executor.programmable_tool_route_is_incomplete",
                details: { missing: missing, task_node_id: node.id },
              )
            end

            unless %w[kernel agent_program].include?(route.implementation_source)
              return nil unless strict

              ValidationError.raise!(
                "programmable tool implementation source is invalid",
                code: "agent_core.dag.task_executor.programmable_tool_route_has_invalid_implementation_source",
                details: {
                  implementation_source: route.implementation_source,
                  task_node_id: node.id,
                },
              )
            end

            route
          end

          def truncate_raw_result(result)
            max_bytes = DEFAULT_MAX_RESULT_BYTES

            json =
              begin
                JSON.generate(result.to_h)
              rescue StandardError
                ""
              end

            return result if json.bytesize <= max_bytes

            truncated = AgentCore::Utils.truncate_utf8_bytes(json, max_bytes: max_bytes)

            AgentCore::Resources::Tools::ToolResult.new(
              content: [{ type: :text, text: truncated }],
              error: result.error?,
              metadata: result.metadata.merge(truncated: true),
            )
          rescue StandardError
            result
          end

          def runtime_name(runtime)
            if runtime.provider.respond_to?(:name)
              runtime.provider.name.to_s
            else
              runtime.provider.class.name
            end
          rescue StandardError
            "unknown"
          end
      end
    end
  end
end
