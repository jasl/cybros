module TurnInternalTasks
  class Materializer
    TERMINAL_STATUSES = %w[finished canceled superseded failed_materialization].freeze
    ACTIVE_STATUSES = %w[materializing materialized running].freeze

    def self.materialize_ready!(graph:)
      new(graph: graph).materialize_ready!
    end

    def initialize(graph:)
      @graph = graph
    end

      def materialize_ready!
        rows = select_rows_to_materialize
        return [] if rows.empty?

        rows.each_with_index.map do |row, index|
          materialize_row!(row)
        rescue StandardError
          rewind_selected_rows!(rows[(index + 1)..])
          raise
        end
      end

    private

      attr_reader :graph

      def select_rows_to_materialize
        rows = []

        TurnInternalTask.transaction do
          graph.turn_internal_tasks
            .where.not(status: TERMINAL_STATUSES)
            .ordered
            .lock
            .to_a
            .group_by(&:turn_id)
            .each_value do |turn_rows|
              rows.concat(select_rows_to_materialize_for_turn(turn_rows))
            end
          end

        rows
      end

      def select_rows_to_materialize_for_turn(turn_rows)
        rows = []
        prefix_parallel = false

        turn_rows.each do |row|
          if prefix_parallel
            break if row.execution_mode != "parallel_safe"

            if row.status == "queued"
              row.update!(status: "materializing")
              rows << row
            elsif ACTIVE_STATUSES.exclude?(row.status)
              break
            end
            next
          end

          if row.execution_mode == "serial"
            if row.status == "queued"
              row.update!(status: "materializing")
              rows << row
            end
            break
          end

          prefix_parallel = true
          if row.status == "queued"
            row.update!(status: "materializing")
            rows << row
          elsif ACTIVE_STATUSES.exclude?(row.status)
            break
          end
        end

        rows
      end

      def materialize_row!(row)
        task = nil
        executable_pending_nodes_created = false
        skipped = false

        graph.with_graph_lock! do
          row.reload
          if row.status != "materializing"
            skipped = true
            next
          end

          mutations = DAG::Mutations.new(graph: graph, turn_id: row.turn_id)
          task =
            mutations.create_node(
              node_type: Messages::Task.node_type_key,
              state: task_state_for(row),
              idempotency_key: "turn_internal_task.materialize:#{row.id}",
              lane_id: row.lane_id,
              metadata: task_metadata(row),
              body_input: task_body_input(row),
            )

          continuation = spliceable_continuation_for(row)
          if continuation.present?
            archive_sequence_edge!(from_node: row.source_node, to_node: continuation)
            mutations.create_edge(from_node: row.source_node, to_node: task, edge_type: DAG::Edge::SEQUENCE)
            mutations.create_edge(from_node: task, to_node: continuation, edge_type: continuation_edge_type_for(row))
          else
            mutations.create_edge(from_node: row.source_node, to_node: task, edge_type: DAG::Edge::SEQUENCE)
          end

          executable_pending_nodes_created =
            mutations.executable_pending_nodes_created? || graph.validate_leaf_invariant!

          row.update!(status: "materialized", materialized_task_node: task)
          emit_direct_tool_activity_events!(task:, row:)
        end

        graph.kick! if executable_pending_nodes_created
        skipped ? nil : row
      rescue StandardError
        row.reload
        row.update!(status: "failed_materialization") if row.status == "materializing"
        raise
      end

      def task_metadata(row)
        base_metadata = {
          "generated_by" => "turn_internal_task_queue",
          "hook_name" => row.source_hook_name,
          "placement" => "append",
          "source_node_id" => row.source_node_id,
          "turn_internal_task_id" => row.id,
          "queue_position" => row.queue_position,
          "authored_metadata" => row.authored_metadata,
        }.compact
        metadata = base_metadata.merge(materialized_task_metadata(row))
        metadata["approval"] = task_approval(row) if task_approval(row).present?
        metadata
      end

      def task_body_input(row)
        envelope = row.operation_envelope
        arguments = AgentCore::Utils.deep_stringify_keys(envelope["arguments"].is_a?(Hash) ? envelope["arguments"] : {})
        row_input = row.input.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(row.input) : {}
        payload = {
          "tool_call_id" => envelope["tool_call_id"],
          "requested_name" => row_input["requested_name"].presence || row.logical_tool_name,
          "name" => row.logical_tool_name,
          "name_resolution" => row_input["name_resolution"].presence || "exact",
          "arguments_resolution" => row_input["arguments_resolution"].presence || "original",
          "arguments" => arguments,
          "arguments_summary" => summarize_arguments(arguments),
          "source" => row_input["source"].presence || "turn_internal_task_queue",
          "logical_tool_name" => row.logical_tool_name,
        }
        payload["repair"] = row_input["repair"] if row_input["repair"].is_a?(Hash)
        payload["approval_preview"] = row_input["approval_preview"] if row_input["approval_preview"].is_a?(Hash)
        payload["reason"] = envelope["reason"] if envelope["reason"].present?
        payload["origin"] = envelope["origin"] if envelope["origin"].present?
        payload["approval_hint"] = envelope["approval_hint"] if envelope["approval_hint"].present?
        payload["idempotency_key"] = envelope["idempotency_key"] if envelope["idempotency_key"].present?
        payload["sequence_id"] = envelope["sequence_id"] if envelope["sequence_id"].present?
        payload["step_index"] = envelope["step_index"] unless envelope["step_index"].nil?
        payload["step_count"] = envelope["step_count"] unless envelope["step_count"].nil?
        payload["capability_registry_snapshot_id"] = row.capability_registry_snapshot_id if row.capability_registry_snapshot_id.present?
        payload["tool_surface_id"] = row.tool_surface_id if row.tool_surface_id.present?
        payload["effective_tool_id"] = row.effective_tool_id if row.effective_tool_id.present?
        payload["implementation_source"] = row.implementation_source if row.implementation_source.present?
        payload["implementation_ref"] = row.implementation_ref if row.implementation_ref.present?
        payload
      end

      def summarize_arguments(arguments)
        json = JSON.generate(arguments)
        AgentCore::Utils.truncate_utf8_bytes(json, max_bytes: 4_000)
      rescue StandardError
        ""
      end

      def spliceable_continuation_for(row)
        direct_tool_continuation = direct_tool_loop_continuation_for(row)
        return direct_tool_continuation if direct_tool_continuation.present?
        return nil unless row.source_node.node_type.to_s == Messages::Task.node_type_key

        child_ids =
          graph.edges.active
            .where(from_node_id: row.source_node_id, edge_type: DAG::Edge::SEQUENCE)
            .order(:id)
            .pluck(:to_node_id)

        return nil if child_ids.empty?

        direct_continuation =
          graph.nodes.active
            .where(id: child_ids, node_type: Messages::AgentMessage.node_type_key)
            .order(:id)
            .to_a
        return direct_continuation.sole if direct_continuation.size == 1
        return nil if direct_continuation.many?

        queue_children =
          graph.nodes.active
            .where(id: child_ids, node_type: Messages::Task.node_type_key)
            .where("metadata ->> 'generated_by' = ?", "turn_internal_task_queue")
            .order(:id)
            .pluck(:id)
        return nil if queue_children.empty?

        continuation_ids =
          graph.edges.active
            .where(from_node_id: queue_children, edge_type: DAG::Edge::SEQUENCE)
            .order(:id)
            .pluck(:to_node_id)

        graph.nodes.active
          .where(id: continuation_ids, node_type: Messages::AgentMessage.node_type_key)
          .distinct
          .order(:id)
          .sole
      rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded
        nil
      end

      def direct_tool_loop_continuation_for(row)
        return nil unless row.source_hook_name.to_s == "agent_message_tool_loop"
        return nil unless row.source_node.node_type.to_s == Messages::AgentMessage.node_type_key

        graph.nodes.active.find_by(
          turn_id: row.turn_id,
          lane_id: row.lane_id,
          node_type: Messages::AgentMessage.node_type_key,
          idempotency_key: "agent_core.next_from:#{row.source_node_id}",
        )
      rescue StandardError
        nil
      end

      def task_state_for(row)
        task_approval(row).present? ? DAG::Node::AWAITING_APPROVAL : DAG::Node::PENDING
      end

      def continuation_edge_type_for(row)
        approval = task_approval(row)
        if approval.is_a?(Hash) && approval["required"] == true && approval["deny_effect"].to_s == "block"
          DAG::Edge::DEPENDENCY
        else
          DAG::Edge::SEQUENCE
        end
      end

      def task_approval(row)
        metadata = row.authored_metadata.is_a?(Hash) ? row.authored_metadata : {}
        approval = metadata["approval"]
        approval.is_a?(Hash) ? approval : nil
      end

      def materialized_task_metadata(row)
        metadata = row.authored_metadata.is_a?(Hash) ? row.authored_metadata : {}
        task_metadata = metadata["task_metadata"]
        task_metadata.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(task_metadata) : {}
      end

      def archive_sequence_edge!(from_node:, to_node:)
        now = Time.current
        graph.edges.active
          .where(
            from_node_id: from_node.id,
            to_node_id: to_node.id,
            edge_type: DAG::Edge::SEQUENCE,
          )
          .update_all(compressed_at: now, updated_at: now)
      end

      def rewind_selected_rows!(rows)
        ids = Array(rows).filter_map(&:id)
        return if ids.empty?

        TurnInternalTask.where(id: ids, status: "materializing").update_all(status: "queued", updated_at: Time.current)
      end

      def emit_direct_tool_activity_events!(task:, row:)
        return unless row.source_hook_name.to_s == "agent_message_tool_loop"
        return unless row.source_node.node_type.to_s == Messages::AgentMessage.node_type_key

        stream = DAG::NodeEventStream.new(node: task)
        activity_kind = direct_tool_activity_kind_for(task)
        diagnostic_level = direct_tool_diagnostic_level_for(row)

        stream.activity_planned!(
          activity_id: "task:#{task.id}",
          activity_kind: activity_kind,
          phase: activity_kind == "preflight_task" ? "preflight" : "planning",
          source_node_id: task.id,
          diagnostic_level: diagnostic_level,
        )

        approval = task_approval(row)
        return unless approval.present?

        stream.activity_waiting!(
          activity_id: "task:#{task.id}",
          activity_kind: activity_kind,
          phase: "authorization",
          source_node_id: task.id,
          diagnostic_level: diagnostic_level,
          data: AgentCore::Utils.deep_stringify_keys(approval),
        )
      end

      def direct_tool_activity_kind_for(task)
        input = task.body_input.is_a?(Hash) ? task.body_input : {}
        tool_name =
          input.fetch("name", input.fetch("requested_name", input.fetch("logical_tool_name", ""))).to_s
        tool_name == "compress_input" ? "preflight_task" : "tool_call"
      rescue StandardError
        "tool_call"
      end

      def direct_tool_diagnostic_level_for(row)
        level =
          if row.source_node.metadata.is_a?(Hash)
            row.source_node.metadata.dig("turn_execution", "diagnostic_level")
          end

        level.to_s == "debug" ? "debug" : "standard"
      rescue StandardError
        "standard"
      end
  end
end
