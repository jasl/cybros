require "json"

module Cybros
  module ProgrammableAgent
    class HookActionExecutor
      TerminalAction = Data.define(:type, :reason, :message)
      Result = Data.define(:emitted_message, :terminal_action, :deferred_anchor, :created_tasks, :silent_finish)
      BOOTSTRAP_HOOKS = %w[on_conversation_created on_lane_first_user_message].freeze
      QUEUE_BACKED_APPEND_HOOKS = (HookEnvelope::CREATE_TASK_PLACEMENT_POLICY.keys - ["on_conversation_created"]).freeze
      MAX_GENERATED_TOOL_CALL_ID_BYTES = 64

      ACTIVE_PLACEHOLDER_STATES = [
        DAG::Node::PENDING,
        DAG::Node::RUNNING,
        DAG::Node::AWAITING_APPROVAL,
      ].freeze

      def self.execute!(actions:, placeholder_node:, hook_name:, conversation_run: nil, anchor_node: nil, lane: nil)
        new(
          actions: actions,
          placeholder_node: placeholder_node,
          hook_name: hook_name,
          conversation_run: conversation_run,
          anchor_node: anchor_node,
          lane: lane,
        ).execute!
      end

      def initialize(actions:, placeholder_node:, hook_name:, conversation_run: nil, anchor_node: nil, lane: nil)
        @actions = Array(actions)
        @placeholder_node = placeholder_node
        @anchor_node = anchor_node || placeholder_node
        @lane = lane || @anchor_node&.lane || @placeholder_node&.lane
        @hook_name = hook_name.to_s
        @conversation_run = conversation_run
        @emitted_message = nil
        @terminal_action = nil
        @appended_tasks = []
        @prepended_tasks = []
        @continuation_materialized = false
        @prepend_continuation_materialized = false
        @deferred_anchor = false
        @silent_finish = false
      end

        def execute!
        actions.each_with_index do |action, index|
          case action.type
          when "noop"
            next
          when "set_step_status"
            apply_set_step_status!(action)
          when "emit_message"
            apply_emit_message!(action)
          when "finish_silently"
            apply_finish_silently!(action)
          when "halt"
            apply_terminal_action!(action)
          when "deny"
            apply_terminal_action!(action)
          when "create_task"
            apply_create_task!(action, action_index: index)
          else
            AgentCore::ValidationError.raise!(
              "Hook action #{action.type.inspect} is not implemented in this runtime batch.",
              code: "cybros.programmable_agent.runtime.action_not_implemented",
              details: { action_type: action.type.to_s },
            )
          end
        end
        materialize_prepend_continuation!
        materialize_append_continuation!

        Result.new(
          emitted_message: @emitted_message,
          terminal_action: @terminal_action,
          deferred_anchor: @deferred_anchor,
          created_tasks: (prepended_tasks + appended_tasks).uniq,
          silent_finish: @silent_finish,
        )
      end

        private

        attr_reader :actions, :placeholder_node, :anchor_node, :hook_name, :lane, :conversation_run

        def apply_set_step_status!(action)
          node = placeholder_node
          ensure_active_placeholder!(node)

          content = action.text.to_s.truncate(node.body.preview_max_chars)
          output_preview = node.body.output_preview.is_a?(Hash) ? node.body.output_preview.deep_stringify_keys : {}
          output_preview["content"] = content
          DAG::NodeBody.where(id: node.body_id).update_all(
            output_preview: output_preview,
            updated_at: Time.current,
          )
          node.body.reload

          DAG::NodeEvent.create!(
            graph_id: node.graph_id,
            node_id: node.id,
            turn_id: node.turn_id,
            body_id: node.body_id,
            kind: DAG::NodeEvent::OUTPUT_COMPACTED,
            text: content,
            payload: {},
          )
        end

        def apply_emit_message!(action)
          ensure_active_placeholder!(placeholder_node)

          message =
            case action.message
            when Hash
              AgentCore::Utils.deep_stringify_keys(action.message)
            else
              { "role" => "assistant", "content" => action.message.to_s }
            end
          message["role"] = "assistant" if message["role"].to_s.strip.empty?

          @emitted_message = message
        end

        def apply_finish_silently!(_action)
          ensure_active_placeholder!(placeholder_node)
          DAG::NodeBody.where(id: placeholder_node.body_id).update_all(output_preview: {}, updated_at: Time.current) if placeholder_node.body_id.present?
          placeholder_node.body.reload if placeholder_node.body_id.present?
          @silent_finish = true
        end

        def apply_create_task!(action, action_index:)
          case action.placement.to_s
          when "prepend"
            apply_prepend_task!(action, action_index: action_index)
          when "append"
            apply_append_task!(action, action_index: action_index)
          else
            AgentCore::ValidationError.raise!(
              "Hook action #{action.type.inspect} placement #{action.placement.inspect} is not implemented in this runtime batch.",
              code: "cybros.programmable_agent.runtime.action_not_implemented",
              details: { action_type: action.type.to_s, placement: action.placement.to_s },
            )
          end
        end

        def apply_terminal_action!(action)
          ensure_active_placeholder!(placeholder_node)
          @terminal_action =
            TerminalAction.new(
              type: action.type,
              reason: action.reason.to_s.presence,
              message: action.message.to_s.presence,
            )
        end

        def apply_append_task!(action, action_index:)
          if direct_bootstrap_append_hook?
            apply_bootstrap_append_task!(action, action_index: action_index)
            return
          end

          ensure_active_placeholder!(placeholder_node) unless queue_backed_append_hook?

          manifest, tool_route = route_for_created_task!(action)
          enqueue_append_task!(action, action_index: action_index, manifest: manifest, tool_route: tool_route)
        end

        def apply_bootstrap_append_task!(action, action_index:)
          bootstrap_lane = bootstrap_lane_for_append!
          bootstrap_graph = bootstrap_lane.graph
          bootstrap_turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
          task = nil

          bootstrap_graph.mutate!(turn_id: bootstrap_turn_id, kick: false) do |m|
            task =
              m.create_node(
                node_type: Messages::Task.node_type_key,
                state: DAG::Node::PENDING,
                idempotency_key: created_task_idempotency_key(action_index, placement: "append"),
                lane_id: bootstrap_lane.id,
                metadata: created_task_metadata(action, action_index: action_index),
                body_input: created_task_input(action, tool_route: nil, manifest: nil, action_index: action_index),
              )
            m.create_edge(from_node: anchor_node, to_node: task, edge_type: DAG::Edge::SEQUENCE) if anchor_node.present?
          end

          appended_tasks << task
        end

        def apply_prepend_task!(action, action_index:)
          ensure_active_placeholder!(placeholder_node)
          ensure_task_anchor_for_prepend!

          node = anchor_node
          manifest, tool_route = route_for_created_task!(action)

          graph = node.graph
          task = nil
          graph.mutate!(turn_id: node.turn_id) do |m|
            anchor = prepended_tasks.last || anchor_node
            task =
              m.create_node(
                node_type: Messages::Task.node_type_key,
                state: DAG::Node::PENDING,
                idempotency_key: created_task_idempotency_key(action_index, placement: "prepend"),
                lane_id: node.lane_id,
                metadata: created_task_metadata(action, action_index: action_index),
                body_input: created_task_input(action, tool_route: tool_route, manifest: manifest, action_index: action_index),
              )
            m.create_edge(from_node: anchor, to_node: task, edge_type: DAG::Edge::SEQUENCE)
          end

          prepended_tasks << task
        end

        def materialize_prepend_continuation!
          return if prepend_continuation_materialized
          return if prepended_tasks.empty?

          node = anchor_node
          graph = node.graph
          clone_input = deferred_anchor_input(node)
          clone_metadata =
            AgentCore::Utils.deep_stringify_keys(node.metadata.is_a?(Hash) ? node.metadata : {}).merge(
              "generated_by" => "programmable_agent_hook",
              "hook_name" => hook_name,
              "deferred_from_node_id" => node.id,
              "deferred_from_tool_call_id" => original_tool_call_id(node),
              "placement" => "prepend",
            ).compact
          graph.mutate!(turn_id: node.turn_id) do |m|
            deferred =
              m.create_node(
                node_type: node.node_type,
                state: DAG::Node::PENDING,
                idempotency_key: prepend_continuation_idempotency_key,
                lane_id: node.lane_id,
                metadata: clone_metadata,
                body_input: clone_input,
              )
            m.create_edge(from_node: prepended_tasks.last, to_node: deferred, edge_type: DAG::Edge::SEQUENCE)
          end

          @prepend_continuation_materialized = true
          @deferred_anchor = true
        end

        def materialize_append_continuation!
          return if continuation_materialized
          return if appended_tasks.empty?
          return if bootstrap_hook?

          return if append_continuation_already_materialized?

          node = placeholder_node
          graph = node.graph
          graph.mutate!(turn_id: node.turn_id) do |m|
            continuation = spliceable_append_continuation
            if continuation.present?
              archive_sequence_edge!(from_node: anchor_node, to_node: continuation)
            else
              continuation =
                m.create_node(
                  node_type: node.node_type,
                  state: DAG::Node::PENDING,
                  idempotency_key: append_continuation_idempotency_key,
                  lane_id: node.lane_id,
                  metadata: {
                    "generated_by" => "programmable_agent_hook",
                    "hook_name" => hook_name,
                    "source_node_id" => node.id,
                    "placement" => "append",
                  },
                )
            end
            m.create_edge(from_node: appended_tasks.last, to_node: continuation, edge_type: DAG::Edge::SEQUENCE)
          end

          @continuation_materialized = true
        end

        def ensure_active_placeholder!(node)
          return if active_placeholder_node?(node)

          AgentCore::ValidationError.raise!(
            "hook action requires an active step placeholder.",
            code: "cybros.programmable_agent.runtime.no_active_step_placeholder",
            details: { dag_node_id: node&.id&.to_s },
          )
        end

        def active_placeholder_node?(node)
          node.present? &&
            node.node_type.to_s == Messages::AgentMessage.node_type_key &&
            ACTIVE_PLACEHOLDER_STATES.include?(node.state)
        end

        def created_task_input(action, tool_route:, manifest:, action_index:)
          arguments = AgentCore::Utils.deep_stringify_keys(action.input.is_a?(Hash) ? action.input : {})

          payload = {
            "tool_call_id" => created_task_tool_call_id(action_index, placement: action.placement.to_s),
            "requested_name" => action.logical_tool_name.to_s,
            "name" => action.logical_tool_name.to_s,
            "name_resolution" => "exact",
            "arguments_resolution" => "original",
            "arguments" => arguments,
            "arguments_summary" => summarize_arguments(arguments),
            "source" => "hook_action",
          }

          if tool_route && manifest
            payload["logical_tool_name"] = tool_route.logical_tool_name
            payload["effective_tool_id"] = tool_route.effective_tool_id
            payload["implementation_source"] = tool_route.implementation_source
            payload["implementation_ref"] = tool_route.implementation_ref
            payload["capability_registry_snapshot_id"] = manifest.capability_registry_snapshot.snapshot_id
            payload["tool_surface_id"] = manifest.tool_surface_id
          else
            payload["logical_tool_name"] = action.logical_tool_name.to_s if bootstrap_hook?
          end

          payload
        end

        def created_task_metadata(action, action_index:)
          {
            "generated_by" => "programmable_agent_hook",
            "hook_name" => hook_name,
            "action_type" => action.type,
            "logical_tool_name" => action.logical_tool_name.to_s,
            "placement" => action.placement,
            "action_index" => action_index,
            "source_node_id" => anchor_node&.id,
            "placeholder_node_id" => placeholder_node&.id,
            "authored_metadata" => AgentCore::Utils.deep_stringify_keys(action.metadata),
          }.compact
        end

        def created_task_idempotency_key(action_index, placement:)
          "programmable_hook.#{placement}_task:#{hook_name}:#{task_creation_anchor_identifier}:#{action_index}"
        end

        def created_task_tool_call_id(action_index, placement:)
          generated_tool_call_id(
            "hook_action:#{hook_name}:#{placement}:#{task_creation_anchor_identifier}:#{action_index}",
            fallback: "hook_action:#{placement}:#{action_index}",
          )
        end

        def append_continuation_idempotency_key
          "programmable_hook.append_continuation:#{hook_name}:#{task_creation_anchor_identifier}"
        end

        def prepend_continuation_idempotency_key
          "programmable_hook.prepend_continuation:#{hook_name}:#{task_creation_anchor_identifier}"
        end

        def prepend_continuation_tool_call_id
          generated_tool_call_id(
            "hook_action:#{hook_name}:prepend_continuation:#{task_creation_anchor_identifier}",
            fallback: "hook_action:prepend_continuation",
          )
        end

        def summarize_arguments(arguments)
          json = JSON.generate(arguments)
          AgentCore::Utils.truncate_utf8_bytes(json, max_bytes: 4_000)
        rescue StandardError
          ""
        end

        def tool_surface_manifest_for_create_task!
          @tool_surface_manifest_for_create_task ||= begin
            run = conversation_run_for_create_task!
            snapshot_payload = run.snapshot["capability_snapshot"]
            unless snapshot_payload.is_a?(Hash) && snapshot_payload.any?
              AgentCore::ValidationError.raise!(
                "hook-created tasks require a pinned capability snapshot on the conversation run",
                code: "cybros.programmable_agent.runtime.capability_snapshot_required_for_create_task",
                details: { hook_name: hook_name, conversation_run_id: run.id },
              )
            end

            payload = run.snapshot.dig("draft", "planning", "tool_surface")
            unless payload.is_a?(Hash) && payload.any?
              AgentCore::ValidationError.raise!(
                "hook-created tasks require a validated tool surface on the conversation run",
                code: "cybros.programmable_agent.runtime.tool_surface_required_for_create_task",
                details: { hook_name: hook_name, conversation_run_id: run.id },
              )
            end

            snapshot = Cybros::ProgrammableAgent::CapabilitySnapshot.restore(snapshot_payload)
            Cybros::ProgrammableAgent::ToolSurfaceManifest.restore(
              payload,
              capability_registry_snapshot: snapshot,
            )
          end
        end

        def route_for_created_task!(action)
          if bootstrap_hook?
            ensure_bootstrap_tool_registered!(action.logical_tool_name)
            return [nil, nil]
          end

          manifest = tool_surface_manifest_for_create_task!
          tool_route = manifest.effective_tool_for(action.logical_tool_name)
          return [manifest, tool_route] if tool_route

          AgentCore::ValidationError.raise!(
            "hook-created task could not be routed inside the validated tool surface",
            code: "cybros.programmable_agent.runtime.unroutable_created_task",
            details: {
              hook_name: hook_name,
              logical_tool_name: action.logical_tool_name.to_s,
              tool_surface_id: manifest.tool_surface_id,
              capability_registry_snapshot_id: manifest.capability_registry_snapshot.snapshot_id,
            },
          )
        end

        def bootstrap_hook?
          BOOTSTRAP_HOOKS.include?(hook_name)
        end

        def direct_bootstrap_append_hook?
          hook_name == "on_conversation_created"
        end

        def queue_backed_append_hook?
          QUEUE_BACKED_APPEND_HOOKS.include?(hook_name)
        end

        def bootstrap_lane_for_append!
          return lane if lane.present?

          AgentCore::ValidationError.raise!(
            "bootstrap hook task creation requires a target lane",
            code: "cybros.programmable_agent.runtime.bootstrap_lane_required",
            details: { hook_name: hook_name },
          )
        end

        def ensure_bootstrap_tool_registered!(logical_tool_name)
          registry = Cybros::AgentRuntimeResolver.build_tools_registry
          return if registry.tool_names.include?(logical_tool_name.to_s)

          AgentCore::ValidationError.raise!(
            "bootstrap hook task could not be routed through the kernel tools registry",
            code: "cybros.programmable_agent.runtime.bootstrap_tool_not_registered",
            details: { hook_name: hook_name, logical_tool_name: logical_tool_name.to_s },
          )
        end

        def task_creation_anchor_identifier
          anchor_node&.id&.to_s.presence || "lane:#{bootstrap_lane_for_append!.id}"
        end

        def enqueue_append_task!(action, action_index:, manifest:, tool_route:)
          queue_lane = queue_lane_for_append!
          queue_graph = queue_lane.graph
          queue_turn_id = queue_turn_id_for_append!
          queue_conversation = queue_conversation_for_append!(queue_lane: queue_lane)
          source_fingerprint = created_task_source_fingerprint(action_index)
          routing = queued_routing_metadata(manifest: manifest, tool_route: tool_route)

          queue_graph.with_graph_lock! do
            row =
              TurnInternalTask.find_by(
                turn_id: queue_turn_id,
                source_fingerprint: source_fingerprint,
              )
            next row if row.present?

            row = TurnInternalTask.new(
              turn_id: queue_turn_id,
              source_fingerprint: source_fingerprint,
              conversation: queue_conversation,
              graph: queue_graph,
              lane: queue_lane,
              source_node_id: anchor_node&.id || placeholder_node&.id,
              source_hook_name: hook_name,
              logical_tool_name: action.logical_tool_name.to_s,
              input: AgentCore::Utils.deep_stringify_keys(action.input.is_a?(Hash) ? action.input : {}),
              authored_metadata: AgentCore::Utils.deep_stringify_keys(action.metadata),
              tool_surface_id: routing[:tool_surface_id],
              capability_registry_snapshot_id: routing[:capability_registry_snapshot_id],
              effective_tool_id: routing[:effective_tool_id],
              implementation_source: routing[:implementation_source],
              implementation_ref: routing[:implementation_ref],
              execution_mode: routing[:execution_mode],
              status: "queued",
            )
            row.queue_position ||= next_queue_position_for(queue_graph: queue_graph, turn_id: queue_turn_id)
            row.save!
          end
        end

        def queued_routing_metadata(manifest:, tool_route:)
          return {
            tool_surface_id: nil,
            capability_registry_snapshot_id: nil,
            effective_tool_id: nil,
            implementation_source: nil,
            implementation_ref: nil,
            execution_mode: "serial",
          } if manifest.nil? || tool_route.nil?

          {
            tool_surface_id: manifest.tool_surface_id,
            capability_registry_snapshot_id: manifest.capability_registry_snapshot.snapshot_id,
            effective_tool_id: tool_route.effective_tool_id.to_s.presence,
            implementation_source: tool_route.implementation_source.to_s.presence,
            implementation_ref: tool_route.implementation_ref.to_s.presence,
            execution_mode: tool_route.respond_to?(:execution_mode) ? tool_route.execution_mode.to_s.presence || "serial" : "serial",
          }
        end

        def next_queue_position_for(queue_graph:, turn_id:)
          queue_graph.turn_internal_tasks.where(turn_id: turn_id).maximum(:queue_position).to_i + 10
        end

        def queue_lane_for_append!
          lane || anchor_node&.lane || placeholder_node&.lane || bootstrap_lane_for_append!
        end

        def queue_turn_id_for_append!
          anchor_node&.turn_id || placeholder_node&.turn_id ||
            AgentCore::ValidationError.raise!(
              "turn-scoped append task creation requires a turn id",
              code: "cybros.programmable_agent.runtime.turn_id_required_for_append_queue",
              details: { hook_name: hook_name, dag_node_id: anchor_node&.id&.to_s || placeholder_node&.id&.to_s },
            )
        end

        def queue_conversation_for_append!(queue_lane:)
          attached = queue_lane.attachable
          return attached if attached.is_a?(Conversation)
          return conversation_run.conversation if conversation_run.present?

          AgentCore::ValidationError.raise!(
            "turn-scoped append task creation requires a bound conversation",
            code: "cybros.programmable_agent.runtime.conversation_required_for_append_queue",
            details: { hook_name: hook_name, lane_id: queue_lane.id.to_s },
          )
        end

        def created_task_source_fingerprint(action_index)
          "#{hook_name}:#{task_creation_anchor_identifier}:append:#{action_index}"
        end

        def conversation_run_for_create_task!
          @conversation_run_for_create_task ||=
            @conversation_run ||
            ConversationRun.latest_for_node(anchor_node) ||
            AgentCore::ValidationError.raise!(
              "hook-created tasks require a bound conversation run",
              code: "cybros.programmable_agent.runtime.conversation_run_required_for_create_task",
              details: { hook_name: hook_name, dag_node_id: anchor_node&.id&.to_s },
            )
        end

        def appended_tasks
          @appended_tasks
        end

        def prepended_tasks
          @prepended_tasks
        end

        def continuation_materialized
          @continuation_materialized == true
        end

        def prepend_continuation_materialized
          @prepend_continuation_materialized == true
        end

        def ensure_task_anchor_for_prepend!
          if anchor_node.present? &&
              anchor_node.node_type.to_s == Messages::AgentMessage.node_type_key &&
              anchor_node.id != placeholder_node&.id
            AgentCore::ValidationError.raise!(
              "agent-step prepend must anchor to the current placeholder node",
              code: "cybros.programmable_agent.runtime.prepend_requires_current_step_anchor",
              details: {
                hook_name: hook_name,
                dag_node_id: anchor_node.id.to_s,
                placeholder_node_id: placeholder_node&.id&.to_s,
              },
            )
          end

          return if prepend_anchor_node?(anchor_node)

          AgentCore::ValidationError.raise!(
            "prepend task creation requires a task or live agent-step anchor",
            code: "cybros.programmable_agent.runtime.prepend_requires_task_anchor",
            details: { hook_name: hook_name, dag_node_id: anchor_node&.id&.to_s, node_type: anchor_node&.node_type.to_s },
          )
        end

        def prepend_anchor_node?(node)
          return false unless node.present?

          node_type = node.node_type.to_s
          return true if node_type == Messages::Task.node_type_key
          if node_type == Messages::AgentMessage.node_type_key
            return false unless node.id == placeholder_node&.id

            return active_placeholder_node?(node)
          end

          false
        end

        def deferred_anchor_input(node)
          input = AgentCore::Utils.deep_stringify_keys(node.body_input.is_a?(Hash) ? node.body_input : {})
          return input unless input.key?("tool_call_id")

          input.merge("tool_call_id" => prepend_continuation_tool_call_id)
        end

        def original_tool_call_id(node)
          input = node.body_input.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(node.body_input) : {}
          input["tool_call_id"].to_s.presence
        end

        def generated_tool_call_id(base, fallback:)
          candidate = normalized_generated_tool_call_id_base(base, fallback: fallback)
          id = candidate
          n = 2

          while generated_tool_call_ids.key?(id)
            suffix = "__#{n}"
            available_bytes = [MAX_GENERATED_TOOL_CALL_ID_BYTES - suffix.bytesize, 1].max
            truncated = AgentCore::Utils.truncate_utf8_bytes(candidate, max_bytes: available_bytes)
            truncated = "t" if truncated.blank?
            id = "#{truncated}#{suffix}"
            n += 1
          end

          generated_tool_call_ids[id] = true
          id
        end

        def normalized_generated_tool_call_id_base(base, fallback:)
          candidate = AgentCore::Utils.truncate_utf8_bytes(base.to_s, max_bytes: MAX_GENERATED_TOOL_CALL_ID_BYTES)
          return candidate if candidate.present?

          fallback_id = AgentCore::Utils.truncate_utf8_bytes(fallback.to_s, max_bytes: MAX_GENERATED_TOOL_CALL_ID_BYTES)
          return fallback_id if fallback_id.present?

          "tc_1"
        end

        def generated_tool_call_ids
          @generated_tool_call_ids ||= {}
        end

        def append_continuation_already_materialized?
          append_continuation_node.present?
        end

        def spliceable_append_continuation
          return nil unless anchor_node&.node_type.to_s == Messages::Task.node_type_key

          active_sequence_agent_children_for(anchor_node).sole
        rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded
          nil
        end

        def append_continuation_node
          active_sequence_agent_children_for(appended_tasks.last).sole
        rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded
          nil
        end

        def active_sequence_agent_children_for(node)
          return DAG::Node.none unless node.present?

          child_ids =
            node.graph.edges.active
              .where(from_node_id: node.id, edge_type: DAG::Edge::SEQUENCE)
              .order(:id)
              .pluck(:to_node_id)

          return DAG::Node.none if child_ids.empty?

          node.graph.nodes.active
            .where(id: child_ids, node_type: Messages::AgentMessage.node_type_key)
            .order(:id)
        end

        def archive_sequence_edge!(from_node:, to_node:)
          now = Time.current
          from_node.graph.edges.active
            .where(
              from_node_id: from_node.id,
              to_node_id: to_node.id,
              edge_type: DAG::Edge::SEQUENCE,
            )
            .update_all(compressed_at: now, updated_at: now)
        end
    end
  end
end
