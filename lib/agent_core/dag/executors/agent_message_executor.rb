# frozen_string_literal: true

require "json"

module AgentCore
  module DAG
    module Executors
      class AgentMessageExecutor
        def context_mode = :full

        def execute(node:, context:, stream:)
          runtime = AgentCore::DAG.runtime_for(node: node)
          execution_context = build_execution_context(node, runtime: runtime)

          instrumenter = execution_context.instrumenter

          instrumenter.instrument(
            "agent_core.turn",
            run_id: execution_context.run_id,
            dag: { graph_id: node.graph_id.to_s, node_id: node.id.to_s, turn_id: node.turn_id.to_s },
          ) do
            budget = build_prompt_with_budget(node, context_nodes: context, runtime: runtime, execution_context: execution_context)

            llm = call_llm(runtime, budget.built_prompt, stream: stream, execution_context: execution_context)

            message = llm.fetch(:message)
            stop_reason = llm.fetch(:stop_reason)
            usage = llm.fetch(:usage)
            streamed_output = llm.fetch(:streamed_output)
            used_model = llm.fetch(:used_model)
            llm_metadata = llm.fetch(:metadata, {})

            message, tool_call_limit_metadata = apply_tool_call_limit(message, runtime: runtime)

            output_payload = build_agent_output_payload(message, runtime: runtime, stop_reason: stop_reason, model: used_model)

            if message.has_tool_calls? && !can_expand_tool_loop?(node, runtime: runtime)
              content = "Stopped: exceeded max_steps_per_turn."
              override_message = Message.new(role: :assistant, content: content)

              output_payload = build_agent_output_payload(override_message, runtime: runtime, stop_reason: :end_turn, model: used_model)
              output_payload["tool_calls"] = message.tool_calls.map(&:to_h)

              metadata =
                deep_merge_metadata(
                  budget.metadata,
                  deep_merge_metadata(
                    llm_metadata,
                    deep_merge_metadata(tool_call_limit_metadata, { reason: "max_steps_exceeded" })
                  )
                )

              ::DAG::ExecutionResult.finished(content: content, payload: output_payload, metadata: metadata, usage: usage)
            else
              if message.has_tool_calls?
                tool_loop_metadata =
                  expand_tool_loop!(
                    node,
                    message,
                    visible_tools: budget.built_prompt.tools,
                    runtime: runtime,
                    execution_context: execution_context,
                  )
              else
                tool_loop_metadata = {}
              end

              metadata =
                deep_merge_metadata(
                  budget.metadata,
                  deep_merge_metadata(
                    llm_metadata,
                    deep_merge_metadata(tool_call_limit_metadata, tool_loop_metadata)
                  )
                )

              if streamed_output
                ::DAG::ExecutionResult.finished(payload: output_payload, metadata: metadata, usage: usage, streamed_output: true)
              else
                ::DAG::ExecutionResult.finished(content: output_payload.fetch("content"), payload: output_payload, metadata: metadata, usage: usage)
              end
            end
          end
        rescue AgentCore::ContextWindowExceededError => e
          ::DAG::ExecutionResult.errored(
            error: "ContextWindowExceededError: #{e.message}",
            metadata: {
              "context_cost" => {
                "context_window_tokens" => e.context_window,
                "reserved_output_tokens" => e.reserved_output,
                "limit" => e.limit,
                "estimated_tokens" => {
                  "total" => e.estimated_tokens,
                  "messages" => e.message_tokens,
                  "tools" => e.tool_tokens,
                }.compact,
              }.compact,
            }
          )
        rescue AgentCore::ProviderError => e
          ::DAG::ExecutionResult.errored(
            error: "ProviderError: #{e.message}",
            metadata: {
              provider: runtime_name_safe(node),
              status: e.status,
            }.compact,
          )
        rescue StandardError => e
          ::DAG::ExecutionResult.errored(error: "#{e.class}: #{e.message}")
        end

        private

          def build_execution_context(node, runtime:)
            ExecutionContext.new(
              run_id: node.turn_id.to_s,
              instrumenter: runtime.instrumenter,
              attributes: {
                dag: {
                  graph_id: node.graph_id.to_s,
                  node_id: node.id.to_s,
                  lane_id: node.lane_id.to_s,
                  turn_id: node.turn_id.to_s,
                },
              },
            )
          end

          def build_prompt_with_budget(node, context_nodes:, runtime:, execution_context:)
            ContextBudgetManager.new(
              node: node,
              runtime: runtime,
              execution_context: execution_context,
            ).build_prompt(context_nodes: context_nodes)
          end

          def call_llm(runtime, built_prompt, stream:, execution_context:)
            messages = []

            system_prompt = built_prompt.system_prompt.to_s
            if !system_prompt.strip.empty?
              messages << Message.new(role: :system, content: system_prompt)
            end

            built_prompt.messages.each do |msg|
              unless msg.is_a?(Message)
                raise ValidationError, "prompt messages must be AgentCore::Message (got #{msg.class})"
              end
              messages << msg
            end

            options = built_prompt.options.is_a?(Hash) ? built_prompt.options.dup : {}
            options = AgentCore::Utils.deep_symbolize_keys(options)

            use_stream = options.fetch(:stream, true) != false
            options.delete(:stream)

            instrumenter = execution_context.instrumenter

            payload = {
              run_id: execution_context.run_id,
              provider: runtime_name(runtime),
              model: runtime.model,
              stream: use_stream,
            }

            instrumenter.instrument("agent_core.llm.call", payload) do
              failover =
                AgentCore::Resources::Provider::ProviderFailover.call(
                  provider: runtime.provider,
                  requested_model: runtime.model,
                  fallback_models: runtime.fallback_models,
                  messages: messages,
                  tools: built_prompt.tools,
                  stream: use_stream,
                  options: options,
                  instrumenter: instrumenter,
                  run_id: execution_context.run_id,
                )

              used_model = failover.fetch(:used_model)
              attempts = failover.fetch(:attempts)

              payload[:used_model] = used_model if used_model && used_model != runtime.model
              payload[:failover_attempts] = attempts.length if attempts.is_a?(Array) && attempts.length > 1

              llm_metadata = build_failover_metadata(requested_model: runtime.model, used_model: used_model, attempts: attempts)

              if use_stream
                stream_chat(enum: failover.fetch(:response), stream: stream).merge(used_model: used_model, metadata: llm_metadata)
              else
                sync_chat(failover.fetch(:response)).merge(used_model: used_model, metadata: llm_metadata)
              end
            end
          end

          def stream_chat(enum:, stream:)
            final_message = nil
            stop_reason = nil
            usage = nil
            content = +""
            wrote_output_deltas = false

            enum.each do |event|
              case event
              when StreamEvent::TextDelta
                delta = event.text.to_s
                content << delta
                if stream && !delta.empty?
                  stream.output_delta(delta)
                  wrote_output_deltas = true
                end
              when StreamEvent::MessageComplete
                final_message = event.message
              when StreamEvent::Done
                stop_reason = event.stop_reason
                usage = event.usage&.to_h
              when StreamEvent::ErrorEvent
                raise AgentCore::StreamError, event.error.to_s
              else
                # ignore tool call deltas (already captured in MessageComplete)
              end
            end

            final_message ||= Message.new(role: :assistant, content: content)
            stop_reason ||= :end_turn

            {
              message: final_message,
              stop_reason: stop_reason,
              usage: usage,
              streamed_output: wrote_output_deltas,
            }
          end

          def sync_chat(resp)
            {
              message: resp.message,
              stop_reason: resp.stop_reason,
              usage: resp.usage&.to_h,
              streamed_output: false,
            }
          end

          def build_agent_output_payload(message, runtime:, stop_reason:, model:)
            tool_calls = message.has_tool_calls? ? message.tool_calls.map(&:to_h) : []

            {
              "content" => message.text.to_s,
              "message" => message.to_h,
              "tool_calls" => tool_calls,
              "stop_reason" => stop_reason.to_s,
              "model" => model.to_s,
              "provider" => runtime_name(runtime),
            }
          end

          def can_expand_tool_loop?(node, runtime:)
            return false unless runtime.max_steps_per_turn

            turn_id = node.turn_id.to_s
            return false if turn_id.empty?

            count =
              node.graph.nodes.active
                .where(turn_id: turn_id, lane_id: node.lane_id)
                .where(node_type: [Messages::AgentMessage.node_type_key, Messages::CharacterMessage.node_type_key])
                .count

            count < runtime.max_steps_per_turn
          rescue StandardError
            true
          end

          def expand_tool_loop!(node, message, visible_tools:, runtime:, execution_context:)
            graph = node.graph
            tool_policy = runtime.tool_policy

            tool_calls = message.tool_calls
            tool_loop_metadata = {}
            name_resolution_events = []
            tool_name_aliases = runtime.tool_name_aliases
            normalize_index =
              if runtime.tool_name_normalize_fallback
                AgentCore::Resources::Tools::ToolNameResolver.build_normalize_index(runtime.tools_registry.tool_names)
              end

            if should_repair_tool_calls?(tool_calls, runtime: runtime)
              repair_result =
                AgentCore::Resources::Tools::ToolCallRepairLoop.call(
                  provider: runtime.provider,
                  requested_model: runtime.model,
                  fallback_models: runtime.tool_call_repair_fallback_models,
                  tool_calls: tool_calls,
                  visible_tools: visible_tools,
                  max_output_tokens: runtime.tool_call_repair_max_output_tokens,
                  max_attempts: runtime.tool_call_repair_attempts,
                  tool_name_aliases: runtime.tool_name_aliases,
                  tool_name_normalize_fallback: runtime.tool_name_normalize_fallback,
                  options: runtime.llm_options,
                  instrumenter: execution_context.instrumenter,
                  run_id: execution_context.run_id,
                )

              tool_calls = repair_result.fetch(:tool_calls, tool_calls)
              tool_loop_metadata = deep_merge_metadata(tool_loop_metadata, repair_result.fetch(:metadata, {}))
            end

            tasks_created = 0
            awaiting_approval = false
            required_approvals = 0
            denied = 0
            invalid = 0

            graph.mutate!(turn_id: node.turn_id) do |m|
              next_node =
                m.create_node(
                  node_type: node.node_type,
                  state: ::DAG::Node::PENDING,
                  idempotency_key: "agent_core.next_from:#{node.id}",
                  metadata: { "generated_by" => "agent_core.tool_loop" },
                  lane_id: node.lane_id,
                )

              tool_calls.each do |tool_call|
                tool_call_id = tool_call.id.to_s
                requested_name = tool_call.name.to_s

                resolved =
                  resolve_tool(
                    runtime.tools_registry,
                    requested_name,
                    aliases: tool_name_aliases,
                    enable_normalize_fallback: runtime.tool_name_normalize_fallback,
                    normalize_index: normalize_index,
                  )
                resolved_name = resolved.name
                source = resolved.source

                if resolved.exists && resolved.resolution_method != :exact && name_resolution_events.length < 20
                  name_resolution_events <<
                    {
                      "tool_call_id" => tool_call_id,
                      "requested_name" => requested_name.to_s,
                      "resolved_name" => resolved_name.to_s,
                      "method" => resolved.resolution_method.to_s,
                    }
                end

                arguments = tool_call.arguments || {}
                parse_error = tool_call.arguments_parse_error

                if parse_error
                  invalid += 1
                  tool_error = AgentCore::Resources::Tools::ToolResult.error(text: "Invalid tool arguments (#{parse_error}).")

                  task =
                    m.create_node(
                      node_type: Messages::Task.node_type_key,
                      state: ::DAG::Node::FINISHED,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => "invalid_args" },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: resolved.resolution_method,
                        arguments: arguments,
                        source: "invalid_args",
                      ),
                      body_output: { "result" => tool_error.to_h },
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                  next
                end

                unless resolved.exists
                  denied += 1

                  tool_error =
                    AgentCore::Resources::Tools::ToolResult.error(
                      text: "Tool not found: #{requested_name}"
                    )

                  task =
                    m.create_node(
                      node_type: Messages::Task.node_type_key,
                      state: ::DAG::Node::FINISHED,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => "policy" },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: resolved.resolution_method,
                        arguments: arguments,
                        source: "policy",
                      ),
                      body_output: { "result" => tool_error.to_h },
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                  next
                end

                decision =
                  begin
                    tool_policy.authorize(name: resolved_name, arguments: arguments, context: execution_context)
                  rescue StandardError => e
                    AgentCore::Resources::Tools::Policy::Decision.deny(reason: "policy_error=#{e.class}")
                  end

                instrument_authorization(execution_context, resolved_name, decision)

                case decision.outcome
                when :allow
                  task =
                    m.create_node(
                      node_type: Messages::Task.node_type_key,
                      state: ::DAG::Node::PENDING,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => source },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: resolved.resolution_method,
                        arguments: arguments,
                        source: source,
                      ),
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)

                  tasks_created += 1
                when :confirm
                  awaiting_approval = true

                  approval = {
                    "required" => decision.required == true,
                    "deny_effect" => decision.deny_effect.to_s,
                    "reason" => decision.reason.to_s,
                  }.compact

                  required_approvals += 1 if decision.required == true

                  task =
                    m.create_node(
                      node_type: Messages::Task.node_type_key,
                      state: ::DAG::Node::AWAITING_APPROVAL,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => source, "approval" => approval },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: resolved.resolution_method,
                        arguments: arguments,
                        source: source,
                      ),
                    )

                  edge_type = decision.required == true && decision.deny_effect.to_s == "block" ? ::DAG::Edge::DEPENDENCY : ::DAG::Edge::SEQUENCE

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: edge_type)

                  tasks_created += 1
                else
                  denied += 1

                  tool_error =
                    AgentCore::Resources::Tools::ToolResult.error(
                      text: "Tool '#{resolved_name}' denied by policy (reason=#{decision.reason})."
                    )

                  task =
                    m.create_node(
                      node_type: Messages::Task.node_type_key,
                      state: ::DAG::Node::FINISHED,
                      idempotency_key: "agent_core.tool:#{node.id}:#{tool_call_id}",
                      lane_id: node.lane_id,
                      metadata: { "generated_by" => "agent_core", "source" => "policy" },
                      body_input: task_input_hash(
                        tool_call_id: tool_call_id,
                        requested_name: requested_name,
                        name: resolved_name,
                        name_resolution: resolved.resolution_method,
                        arguments: arguments,
                        source: "policy",
                      ),
                      body_output: { "result" => tool_error.to_h },
                    )

                  m.create_edge(from_node: node, to_node: task, edge_type: ::DAG::Edge::SEQUENCE)
                  m.create_edge(from_node: task, to_node: next_node, edge_type: ::DAG::Edge::SEQUENCE)
                end
              end
            end

            if awaiting_approval
              execution_context.instrumenter.publish(
                "agent_core.pause",
                run_id: execution_context.run_id,
                kind: "awaiting_approval",
              )
            end

            if name_resolution_events.any?
              tool_loop_metadata =
                deep_merge_metadata(
                  tool_loop_metadata,
                  {
                    tool_loop: {
                      tool_name_resolution: name_resolution_events,
                    },
                  }
                )
            end

            deep_merge_metadata(
              tool_loop_metadata,
              {
                tool_loop: {
                  tasks_created: tasks_created,
                  awaiting_approval: awaiting_approval,
                  required_approvals: required_approvals,
                  denied: denied,
                  invalid: invalid,
                }.compact,
              }
            )
          end

          def apply_tool_call_limit(message, runtime:)
            return [message, {}] unless message&.has_tool_calls?

            limit = runtime.max_tool_calls_per_turn
            return [message, {}] if limit.nil?

            tool_calls = Array(message.tool_calls)
            return [message, {}] if tool_calls.length <= limit

            kept = tool_calls.first(limit)
            dropped = tool_calls.drop(limit)

            dropped_names =
              dropped
                .first(10)
                .map { |tc| tc.respond_to?(:name) ? tc.name.to_s : "" }
                .map(&:strip)
                .reject(&:empty?)
                .map { |name| AgentCore::Utils.truncate_utf8_bytes(name, max_bytes: 200) }

            truncated_message =
              Message.new(
                role: message.role,
                content: message.content,
                tool_calls: kept,
                tool_call_id: message.tool_call_id,
                name: message.name,
                metadata: message.metadata,
              )

            metadata = {
              tool_loop: {
                tool_calls_limit: limit,
                tool_calls_total: tool_calls.length,
                tool_calls_executed: kept.length,
                tool_calls_omitted: dropped.length,
                tool_calls_omitted_names_sample: dropped_names,
              }.compact,
            }

            [truncated_message, metadata]
          rescue StandardError
            [message, {}]
          end

          ResolvedTool = Data.define(:name, :source, :exists, :resolution_method)

          def resolve_tool(registry, requested_name, aliases:, enable_normalize_fallback:, normalize_index:)
            resolution =
              AgentCore::Resources::Tools::ToolNameResolver.resolve(
                requested_name,
                include_check: ->(name) { registry.include?(name) },
                aliases: aliases,
                enable_normalize_fallback: enable_normalize_fallback,
                normalize_index: normalize_index,
              )

            resolved_name = resolution.resolved_name

            tool_info = registry.find(resolved_name)
            source =
              case tool_info
              when AgentCore::Resources::Tools::Tool
                if resolved_name.start_with?(AgentCore::Resources::Skills::Tools::DEFAULT_TOOL_NAME_PREFIX)
                  "skills"
                else
                  "native"
                end
              when Hash
                "mcp"
              else
                "policy"
              end

            ResolvedTool.new(name: resolved_name, source: source, exists: !tool_info.nil?, resolution_method: resolution.method)
          rescue StandardError
            ResolvedTool.new(name: requested_name.to_s, source: "policy", exists: false, resolution_method: :unknown)
          end

          def task_input_hash(tool_call_id:, requested_name:, name:, name_resolution:, arguments:, source:)
            arguments = arguments.is_a?(Hash) ? arguments : {}

            {
              "tool_call_id" => tool_call_id.to_s,
              "requested_name" => requested_name.to_s,
              "name" => name.to_s,
              "name_resolution" => name_resolution.to_s,
              "arguments" => AgentCore::Utils.deep_stringify_keys(arguments),
              "arguments_summary" => summarize_arguments(arguments),
              "source" => source.to_s,
            }
          end

          def summarize_arguments(arguments)
            json = JSON.generate(arguments)
            AgentCore::Utils.truncate_utf8_bytes(json, max_bytes: 4_000)
          rescue StandardError
            ""
          end

          def instrument_authorization(execution_context, tool_name, decision)
            execution_context.instrumenter.publish(
              "agent_core.tool.authorize",
              run_id: execution_context.run_id,
              tool: tool_name.to_s,
              outcome: decision.outcome.to_s,
              required: decision.required == true,
            )
          rescue StandardError
            nil
          end

          def deep_merge_metadata(a, b)
            a = a.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(a) : {}
            b = b.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(b) : {}
            a.deep_merge(b)
          rescue StandardError
            a.merge(b)
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

          def runtime_name_safe(node)
            runtime = AgentCore::DAG.runtime_for(node: node)
            runtime_name(runtime)
          rescue StandardError
            nil
          end

          def build_failover_metadata(requested_model:, used_model:, attempts:)
            requested = requested_model.to_s
            used = used_model.to_s

            return {} if used.empty? || used == requested || !attempts.is_a?(Array) || attempts.length <= 1

            {
              "llm" => {
                "failover" => {
                  "requested_model" => requested,
                  "used_model" => used,
                  "attempts" => attempts,
                },
              },
            }
          rescue StandardError
            {}
          end

          def should_repair_tool_calls?(tool_calls, runtime:)
            attempts = Integer(runtime.tool_call_repair_attempts)
            return false if attempts <= 0

            Array(tool_calls).any? do |tc|
              err = tc.respond_to?(:arguments_parse_error) ? tc.arguments_parse_error : nil
              err_str = err.to_s
              err_str == "invalid_json" || err_str == "too_large"
            end
          rescue StandardError
            false
          end
      end
    end
  end
end
