module Statistics
  class ToolCallFactProjector
    AGENT_NODE_TYPES = [
      Messages::AgentMessage.node_type_key,
      Messages::CharacterMessage.node_type_key,
    ].freeze
    PREFLIGHT_TOOL_NAMES = %w[compress_input compact_context].freeze
    TOOL_ARGUMENT_RESOLUTION_VALUES = %w[original repaired invalid].freeze

    class << self
      def project!(task_node)
        new(task_node: task_node).project!
      end
    end

    def initialize(task_node:)
      @task = task_node
    end

    def project!
      return delete_existing_fact! unless eligible_task?

      fact = Statistics::ToolCallFact.find_or_initialize_by(task_node_id: task.id)
      fact.assign_attributes(projected_attributes)
      fact.save!
      fact
    end

    private

      attr_reader :task

      def projected_attributes
        {
          retry_of_task_node_id: retry_of_task_node_id,
          conversation_id: conversation.id,
          root_conversation_id: root_conversation.id,
          user_id: conversation.user_id,
          graph_id: task.graph_id,
          turn_id: task.turn_id,
          sample_origin: sample_origin,
          execution_scope: execution_scope,
          tool_call_id: body_input["tool_call_id"].to_s.presence,
          requested_name: requested_name,
          resolved_name: resolved_name,
          name_resolution: body_input["name_resolution"].to_s.presence,
          arguments_resolution: arguments_resolution,
          model_attempt_class: model_attempt_class,
          source: source,
          provider_key: provider_key,
          model_ref: model_ref,
          execution_readiness: execution_readiness,
          entered_execution: entered_execution?,
          tool_outcome: tool_outcome,
          failure_class: failure_class,
          failure_code: failure_code,
          retryable: retryable,
          manual_retry: manual_retry?,
          started_at: task.started_at,
          finished_at: task.finished_at,
          effective_on: effective_on,
          duration_ms: duration_ms,
        }
      end

      def eligible_task?
        return false unless task.is_a?(DAG::Node)
        return false unless task.node_type.to_s == Messages::Task.node_type_key
        return false unless conversation
        return false if preflight_task?

        true
      end

      def delete_existing_fact!
        Statistics::ToolCallFact.where(task_node_id: task&.id).delete_all if task.respond_to?(:id)
        nil
      end

      def preflight_task?
        names = [resolved_name, requested_name, body_input["name"]].compact.map(&:to_s)
        names.any? { |name| PREFLIGHT_TOOL_NAMES.include?(name) }
      end

      def conversation
        @conversation ||=
          begin
            attachable = task.graph&.attachable
            attachable if attachable.is_a?(Conversation)
          end
      end

      def root_conversation
        @root_conversation ||= conversation&.root_conversation || conversation
      end

      def sample_origin
        root_conversation&.statistics_sample_origin || conversation&.statistics_sample_origin || Conversation::DEFAULT_STATISTICS_SAMPLE_ORIGIN
      end

      def execution_scope
        subagent = conversation&.metadata
        subagent = subagent.is_a?(Hash) ? subagent["subagent"] : nil
        subagent = subagent.is_a?(Hash) ? subagent : {}

        if subagent["parent_conversation_id"].present? && subagent["parent_graph_id"].present? && subagent["spawned_from_node_id"].present?
          "subagent_child"
        else
          "parent"
        end
      end

      def body_input
        @body_input ||= task.body_input.is_a?(Hash) ? task.body_input.deep_stringify_keys : {}
      end

      def body_output
        @body_output ||= task.body_output.is_a?(Hash) ? task.body_output.deep_stringify_keys : {}
      end

      def requested_name
        body_input["requested_name"].to_s.presence || body_input["name"].to_s.presence
      end

      def resolved_name
        body_input["name"].to_s.presence || body_input["requested_name"].to_s.presence
      end

      def source
        body_input["source"].to_s.presence || task.metadata&.dig("source").to_s.presence
      end

      def arguments_resolution
        value = body_input["arguments_resolution"].to_s
        return value if TOOL_ARGUMENT_RESOLUTION_VALUES.include?(value)
        return "invalid" if raw_arguments_invalid?

        "original"
      end

      def model_attempt_class
        repair = body_input["repair"]
        repair = repair.is_a?(Hash) ? repair.deep_stringify_keys : {}

        name_repaired = repair["tool_name"] == true || body_input["name_resolution"].to_s == "repaired"
        args_repaired = repair["arguments"] == true || arguments_resolution == "repaired"

        if name_repaired && args_repaired
          "repaired_both"
        elsif name_repaired
          "repaired_name"
        elsif args_repaired
          "repaired_args"
        else
          "first_pass"
        end
      end

      def provider_key
        upstream_agent_output["provider_key"].to_s.presence || upstream_agent_output["provider"].to_s.presence
      end

      def model_ref
        upstream_agent_output["model_ref"].to_s.presence || upstream_agent_output["model"].to_s.presence
      end

      def upstream_agent_output
        @upstream_agent_output ||=
          begin
            output = upstream_agent_node&.body_output
            output.is_a?(Hash) ? output.deep_stringify_keys : {}
          end
      end

      def upstream_agent_node
        @upstream_agent_node ||= begin
          incoming_agent_ids =
            task.graph.edges
              .where(to_node_id: task.id, edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)
              .order(:created_at, :id)
              .pluck(:from_node_id)

          if incoming_agent_ids.any?
            nodes_by_id =
              task.graph.nodes
                .where(id: incoming_agent_ids, node_type: AGENT_NODE_TYPES, turn_id: task.turn_id)
                .index_by(&:id)

            incoming_agent_ids.reverse_each.filter_map { |node_id| nodes_by_id[node_id] }.first ||
              fallback_upstream_agent_node
          else
            fallback_upstream_agent_node
          end
        end
      end

      def fallback_upstream_agent_node
        task.graph.nodes
          .where(turn_id: task.turn_id, lane_id: task.lane_id, node_type: AGENT_NODE_TYPES)
          .where.not(id: task.id)
          .order(:created_at, :id)
          .first
      end

      def execution_readiness
        return "awaiting_approval" if task.awaiting_approval?
        return "approval_rejected" if approval_rejected?
        return "invalid_args" if invalid_args?
        return "tool_not_found" if tool_not_found?
        return "policy_denied" if policy_denied?

        "executable"
      end

      def tool_outcome
        return "not_executed" unless execution_readiness == "executable"

        if task.finished?
          tool_result_error? ? "failed" : "success"
        elsif task.errored? || task.stopped? || task.skipped? || executable_rejected?
          "failed"
        else
          "not_executed"
        end
      end

      def failure_class
        return nil unless tool_outcome == "failed"

        value = tool_execution_metadata["failure_class"].to_s
        return value if Statistics::ToolCallFact::FAILURE_CLASSES.include?(value)

        "unknown"
      end

      def failure_code
        return nil unless tool_outcome == "failed"

        tool_execution_metadata["failure_code"].to_s.presence
      end

      def retryable
        return nil unless tool_outcome == "failed"
        return tool_execution_metadata["retryable"] if tool_execution_metadata.key?("retryable")

        nil
      end

      def tool_execution_metadata
        metadata = tool_result&.metadata
        metadata = metadata.is_a?(Hash) ? metadata["tool_execution"] : nil
        metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
      end

      def tool_result
        @tool_result ||= begin
          [body_output["raw_result"], body_output["result"]].filter_map do |candidate|
            next if candidate.nil?

            begin
              AgentCore::Resources::Tools::ToolResult.from_h(candidate)
            rescue StandardError
              nil
            end
          end.first
        end
      end

      def tool_result_error?
        tool_result&.error? == true
      end

      def invalid_args?
        raw_arguments_invalid? || source == "invalid_args"
      end

      def raw_arguments_invalid?
        body_input["arguments_resolution"].to_s == "invalid"
      end

      def tool_not_found?
        result_text.start_with?("Tool not found:")
      end

      def policy_denied?
        return false if tool_not_found?

        source == "policy" || result_text.include?("denied by policy")
      end

      def approval_rejected?
        return false unless task.rejected?

        reason = task.metadata.is_a?(Hash) ? task.metadata["reason"].to_s : ""
        reason == "approval_denied" || task.metadata.is_a?(Hash) && task.metadata["approval"].is_a?(Hash)
      end

      def executable_rejected?
        task.rejected? && execution_readiness == "executable"
      end

      def result_text
        @result_text ||= tool_result&.text.to_s
      end

      def entered_execution?
        task.started_at.present?
      end

      def retry_of_task_node_id
        task.retry_of_id || rerun_source_task_node_id
      end

      def manual_retry?
        retry_of_task_node_id.present?
      end

      def rerun_source_task_node_id
        @rerun_source_task_node_id ||= begin
          branch_edge =
            task.graph.edges
              .where(to_node_id: task.id, edge_type: DAG::Edge::BRANCH)
              .order(:created_at, :id)
              .detect do |edge|
                branch_kinds = edge.metadata.is_a?(Hash) ? Array(edge.metadata["branch_kinds"]).map(&:to_s) : []
                branch_kinds.include?("rerun")
              end

          return nil unless branch_edge

          source_node = task.graph.nodes.find_by(id: branch_edge.from_node_id)
          return nil unless source_node&.node_type.to_s == Messages::Task.node_type_key

          source_node.id
        end
      end

      def effective_on
        (task.finished_at || task.started_at)&.to_date
      end

      def duration_ms
        return nil if task.started_at.blank? || task.finished_at.blank?

        ((task.finished_at - task.started_at) * 1000).round
      end
  end
end
