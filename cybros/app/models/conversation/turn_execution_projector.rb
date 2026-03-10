class Conversation::TurnExecutionProjector
  PREFLIGHT_TASK_NAMES = %w[compress_input].freeze
  SUBAGENT_TOOL_NAMES = %w[subagent_run subagent_wait].freeze
  ASSISTANT_BUBBLE = "assistant_bubble"
  COMPOSER_ONLY = "composer_only"
  STANDARD_DIAGNOSTIC_LEVEL = "standard"
  DEBUG_DIAGNOSTIC_LEVEL = "debug"
  RUN_STATE_ACTIVITY_PREVIEW_LIMIT = 3
  NO_RUN_STATE = :no_run_state

  def initialize(conversation: nil, graph: nil, lane_id: nil)
    @conversation = conversation
    @graph = graph || conversation&.root_graph
    @lane_id = lane_id || conversation&.chat_lane&.id

    raise ArgumentError, "graph is required" if @graph.nil?
    raise ArgumentError, "lane_id is required" if @lane_id.blank?
  end

  def turn_execution_for_turn_id(turn_id)
    turn_id = turn_id.to_s
    return nil if turn_id.blank?

    turn = @graph.turns.find_by(id: turn_id)
    turn_nodes = scoped_nodes.where(turn_id: turn_id).includes(:body, :node_events).order(:id).to_a
    return nil if turn_nodes.empty?

    turn_head = turn_head_node_for(turn: turn, turn_nodes: turn_nodes)
    execution_node = execution_node_for(turn_nodes)
    diagnostic_level = diagnostic_level_for(execution_node)
    activities = project_activities(turn_nodes, diagnostic_level: diagnostic_level)

    {
      "turn_id" => turn_id,
      "head_node_id" => turn_head&.id,
      "status" => reduce_status(execution_node: execution_node, activities: activities),
      "phase" => reduce_phase(execution_node: execution_node, activities: activities),
      "diagnostic_level" => diagnostic_level,
      "event_cursor" => event_cursor_for(turn_nodes),
      "started_at" => started_at_for(turn_nodes),
      "updated_at" => updated_at_for(turn_nodes),
      "finished_at" => finished_at_for(execution_node: execution_node, activities: activities),
      "summary" => summary_for(activities),
      "activities" => activities,
    }
  end

  def turn_execution_for_node_id(node_id)
    node = scoped_nodes.find_by(id: node_id.to_s)
    return nil if node.nil?

    turn_execution_for_turn_id(node.turn_id)
  end

  def execution_rollup_for_turn_id(turn_id)
    execution = turn_execution_for_turn_id(turn_id)
    return DAG::Turn.empty_execution_rollup_attributes unless execution.is_a?(Hash)

    all_activities = Array(execution.fetch("activities", []))
    visible_activities = assistant_bubble_activities(all_activities)
    preview_activities = visible_activities.last(RUN_STATE_ACTIVITY_PREVIEW_LIMIT)
    hidden_activities = all_activities.reject { |activity| preview_activities.include?(activity) }

    {
      execution_activity_count: visible_activities.length,
      execution_status: execution.fetch("status", nil),
      execution_phase: execution.fetch("phase", nil),
      execution_diagnostic_level: execution.fetch("diagnostic_level", nil),
      execution_event_cursor: execution.fetch("event_cursor", nil),
      execution_summary: summary_for(visible_activities),
      execution_hidden_summary: summary_for(hidden_activities),
      execution_preview_activities: preview_activities,
      execution_updated_at: iso8601_time(execution.fetch("updated_at", nil)),
    }
  end

  def run_state_for_node_id(node_id)
    node = scoped_nodes.find_by(id: node_id.to_s)
    return nil unless assistant_message_node?(node)

    turn = @graph.turns.find_by(id: node.turn_id)
    rollup = run_state_rollup_for(turn)
    return nil if rollup == NO_RUN_STATE
    return rollup if rollup

    execution = turn_execution_for_turn_id(node.turn_id)
    return nil unless execution.is_a?(Hash)

    all_activities = Array(execution.fetch("activities", []))
    visible_activities = assistant_bubble_activities(all_activities)
    preview_activities = visible_activities.last(RUN_STATE_ACTIVITY_PREVIEW_LIMIT)
    hidden_summary = summary_for(all_activities.reject { |activity| preview_activities.include?(activity) })
    hidden_notice = hidden_notice?(hidden_summary)

    return nil if visible_activities.empty? && !hidden_notice

    {
      "status" => execution.fetch("status"),
      "phase" => execution.fetch("phase"),
      "diagnostic_level" => execution.fetch("diagnostic_level"),
      "event_cursor" => execution["event_cursor"],
      "summary" => summary_for(visible_activities),
      "hidden_summary" => hidden_summary,
      "activities" => preview_activities,
    }
  end

  private

    def scoped_nodes
      @graph.nodes.active.where(lane_id: @lane_id)
    end

    def turn_head_node_for(turn:, turn_nodes:)
      head_id = turn&.start_message_node_id
      if head_id.present?
        matched = turn_nodes.find { |node| node.id.to_s == head_id.to_s }
        return matched if matched
      end

      message_nodes = turn_nodes.select { |node| message_node?(node) }
      return earliest_node(message_nodes) if message_nodes.any?

      earliest_node(turn_nodes)
    end

    def execution_node_for(turn_nodes)
      message_nodes = turn_nodes.select { |node| message_node?(node) }
      return message_nodes.last if message_nodes.any?

      turn_nodes.last
    end

    def earliest_node(nodes)
      Array(nodes).compact.min_by { |node| [node.created_at, node.id.to_s] }
    end

    def project_activities(turn_nodes, diagnostic_level:)
      tasks = turn_nodes.select { |node| node.node_type.to_s == Messages::Task.node_type_key }

      projected =
        tasks.each_with_index.map do |task, index|
          project_activity(task, sequence_fallback: index + 1, diagnostic_level: diagnostic_level)
        end

      projected.sort_by { |activity| [activity.fetch("sequence"), activity.fetch("source_node_id").to_s] }
    end

    def project_activity(task, sequence_fallback:, diagnostic_level:)
      activity_events = task.node_events.select { |event| activity_event?(event) }.sort_by(&:created_at)
      last_event = activity_events.last
      last_payload = last_event&.payload.is_a?(Hash) ? last_event.payload : {}
      subagent_snapshot = subagent_snapshot_for(task)
      subagent_activity = subagent_activity?(task)

      kind = subagent_activity ? "subagent" : (last_payload["kind"].to_s.presence || activity_kind_for(task))
      status =
        if subagent_activity
          subagent_activity_status_for(task, snapshot: subagent_snapshot)
        else
          last_payload["status"].to_s.presence || activity_status_for(task)
        end
      phase =
        if subagent_activity
          subagent_activity_phase_for(status: status, snapshot: subagent_snapshot)
        else
          last_payload["phase"].to_s.presence || activity_phase_for(task, kind: kind, status: status)
        end
      diagnostics = diagnostics_for(activity_events, diagnostic_level: diagnostic_level)
      diagnostics = attach_subagent_diagnostics(diagnostics, snapshot: subagent_snapshot, diagnostic_level: diagnostic_level)

      activity = {
        "activity_id" => last_payload["activity_id"].to_s.presence || "task:#{task.id}",
        "kind" => kind,
        "status" => status,
        "phase" => phase,
        "sequence" => Integer(last_payload["sequence"], exception: false) || sequence_fallback,
        "title" => subagent_activity ? subagent_title_for(task) : activity_title_for(task),
        "source_node_id" => last_payload["source_node_id"].to_s.presence || task.id,
        "tool_call_id" => task.body_input["tool_call_id"].to_s.presence,
        "input_preview" => subagent_activity ? nil : task.body_input["arguments_summary"].to_s.presence,
        "output_preview" => subagent_activity ? subagent_output_preview(subagent_snapshot) : activity_output_preview_for(task),
        "error" => subagent_activity ? subagent_error_for(task, status: status, snapshot: subagent_snapshot, last_payload: last_payload) : activity_error_for(task, status: status, last_payload: last_payload),
        "last_event_id" => last_event&.id,
        "diagnostics" => diagnostics,
        "started_at" => task.started_at&.iso8601,
        "updated_at" => task.updated_at&.iso8601,
        "finished_at" => task.finished_at&.iso8601,
        "visibility" => activity_visibility_for(kind),
      }.compact

      if subagent_activity
        activity["links"] = subagent_links_for(subagent_snapshot)
        activity["snapshot"] = subagent_snapshot_fields(subagent_snapshot)
      end

      activity.compact
    end

    def assistant_bubble_activities(activities)
      Array(activities).select { |activity| activity["visibility"] == ASSISTANT_BUBBLE }
    end

    def hidden_notice?(hidden_summary)
      hidden_summary.fetch("failed_count", 0).to_i.positive? || hidden_summary.fetch("awaiting_count", 0).to_i.positive?
    end

    def run_state_rollup_for(turn)
      return nil if turn.nil?
      return nil unless turn.has_attribute?(:execution_status)

      preview_activities = turn.execution_preview_activities
      hidden_summary = turn.execution_hidden_summary
      hidden_notice = hidden_notice?(hidden_summary)
      return NO_RUN_STATE if rollup_authoritative?(turn: turn, preview_activities: preview_activities, hidden_summary: hidden_summary) && preview_activities.empty? && !hidden_notice
      return nil if preview_activities.empty? && !hidden_notice

      {
        "status" => turn.execution_status,
        "phase" => turn.execution_phase,
        "diagnostic_level" => turn.execution_diagnostic_level || STANDARD_DIAGNOSTIC_LEVEL,
        "event_cursor" => turn.execution_event_cursor,
        "summary" => turn.execution_summary,
        "hidden_summary" => hidden_summary,
        "activities" => preview_activities,
      }
    end

    def rollup_authoritative?(turn:, preview_activities:, hidden_summary:)
      preview_activities.any? ||
        hidden_summary.any? ||
        turn.execution_summary.any? ||
        turn.execution_status.present? ||
        turn.execution_phase.present? ||
        turn.execution_diagnostic_level.present? ||
        turn.execution_event_cursor.present? ||
        turn.execution_updated_at.present?
    end

    def iso8601_time(value)
      return nil if value.blank?

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def activity_kind_for(task)
      PREFLIGHT_TASK_NAMES.include?(activity_title_for(task)) ? "preflight_task" : "tool_call"
    end

    def activity_status_for(task)
      case task.state.to_s
      when DAG::Node::PENDING
        "pending"
      when DAG::Node::AWAITING_APPROVAL
        "awaiting_approval"
      when DAG::Node::RUNNING
        "running"
      when DAG::Node::FINISHED
        "completed"
      when DAG::Node::ERRORED
        "failed"
      when DAG::Node::REJECTED
        "rejected"
      when DAG::Node::SKIPPED
        "skipped"
      when DAG::Node::STOPPED
        "stopped"
      else
        "pending"
      end
    end

    def activity_phase_for(task, kind:, status:)
      return "preflight" if kind == "preflight_task"
      return "authorization" if status == "awaiting_approval"

      case task.state.to_s
      when DAG::Node::ERRORED, DAG::Node::REJECTED, DAG::Node::STOPPED, DAG::Node::SKIPPED
        "terminal"
      else
        "execution"
      end
    end

    def activity_visibility_for(kind)
      kind == "preflight_task" ? COMPOSER_ONLY : ASSISTANT_BUBBLE
    end

    def subagent_activity?(task)
      SUBAGENT_TOOL_NAMES.include?(task_tool_name(task))
    end

    def task_tool_name(task)
      input = task.body_input.is_a?(Hash) ? task.body_input : {}
      input["name"].to_s.presence ||
        input["requested_name"].to_s.presence ||
        input["resolved_name"].to_s.presence
    end

    def activity_title_for(task)
      input = task.body_input
      input["name"].to_s.presence ||
        input["requested_name"].to_s.presence ||
        input["resolved_name"].to_s.presence ||
        task.node_type.to_s
    end

    def subagent_title_for(task)
      input = task.body_input.is_a?(Hash) ? task.body_input : {}
      arguments = input["arguments"].is_a?(Hash) ? input["arguments"] : {}
      arguments["name"].to_s.presence ||
        arguments["title"].to_s.presence ||
        "Subagent"
    end

    def subagent_snapshot_for(task)
      [task.body_output["raw_result"], task.body_output["result"], task.body_output_preview["result"]].compact.each do |candidate|
        tool_result = AgentCore::Resources::Tools::ToolResult.from_h(candidate)
        snapshot = tool_result.metadata["subagent"]
        return snapshot if snapshot.is_a?(Hash)
      rescue StandardError
        next
      end

      nil
    end

    def subagent_links_for(snapshot)
      return nil unless snapshot.is_a?(Hash)

      child_conversation_id = snapshot["child_conversation_id"].to_s.presence
      child_graph_id = snapshot["child_graph_id"].to_s.presence
      links = {}
      links["child_conversation_id"] = child_conversation_id if child_conversation_id
      links["child_graph_id"] = child_graph_id if child_graph_id
      links.presence
    end

    def subagent_snapshot_fields(snapshot)
      return nil unless snapshot.is_a?(Hash)

      snapshot.slice(
        "operation",
        "status",
        "counts",
        "leaf",
        "transcript_lines",
        "wait_status",
        "timed_out",
        "timeout_ms",
        "elapsed_ms",
        "diagnostic_level",
      ).presence
    end

    def subagent_output_preview(snapshot)
      return nil unless snapshot.is_a?(Hash)

      Array(snapshot["transcript_lines"]).last.to_s.presence
    end

    def subagent_activity_status_for(task, snapshot:)
      task_status = activity_status_for(task)
      return task_status unless snapshot.is_a?(Hash)
      return task_status if %w[failed rejected skipped stopped].include?(task_status)

      case snapshot["status"].to_s
      when "running"
        "running"
      when "pending"
        "pending"
      when "awaiting_approval"
        "awaiting_approval"
      when "idle"
        "completed"
      when "missing"
        "failed"
      else
        task_status
      end
    end

    def subagent_activity_phase_for(status:, snapshot:)
      return "authorization" if snapshot.is_a?(Hash) && snapshot["status"].to_s == "awaiting_approval"
      return "terminal" if terminal_activity_status?(status)

      "execution"
    end

    def attach_subagent_diagnostics(diagnostics, snapshot:, diagnostic_level:)
      return diagnostics unless diagnostic_level == DEBUG_DIAGNOSTIC_LEVEL
      return diagnostics unless snapshot.is_a?(Hash)

      base = diagnostics.is_a?(Hash) ? diagnostics.deep_dup : {}
      base["subagent"] = subagent_snapshot_fields(snapshot)
      base
    end

    def activity_error_for(task, status:, last_payload: {})
      return nil unless status == "failed"

      event_error = last_payload.fetch("data", {}).is_a?(Hash) ? last_payload.fetch("data", {}).fetch("error", nil) : nil
      return { "summary" => event_error.to_s } if event_error.present?

      preview = activity_output_preview_for(task).presence || task.body_output_preview["result"].presence || task.body_output["result"]
      return { "summary" => preview.to_s } if preview.present?

      { "summary" => "task failed" }
    end

    def activity_output_preview_for(task)
      task.body_output_preview["activity_preview"].presence ||
        task.body_output["activity_preview"].to_s.presence ||
        task.body_output_preview["result"].presence
    rescue StandardError
      task.body_output_preview["result"].presence
    end

    def subagent_error_for(task, status:, snapshot:, last_payload:)
      return nil unless status == "failed"

      if snapshot.is_a?(Hash) && snapshot["status"].to_s == "missing"
        return { "summary" => "child conversation missing" }
      end

      activity_error_for(task, status: status, last_payload: last_payload)
    end

    def reduce_status(execution_node:, activities:)
      statuses = Array(activities).map { |activity| activity.fetch("status") }
      execution_state = execution_node&.state.to_s

      return "stopped" if execution_state == DAG::Node::STOPPED || statuses.include?("stopped")
      return "running" if statuses.include?("running")
      return "awaiting_approval" if statuses.include?("awaiting_approval")
      return "failed" if statuses.include?("failed")
      return "completed" if statuses.present? && statuses.all? { |status| terminal_activity_status?(status) }
      return "pending" if statuses.any? { |status| pending_activity_status?(status) }

      case execution_state
      when DAG::Node::RUNNING
        "running"
      when DAG::Node::PENDING
        "pending"
      when DAG::Node::AWAITING_APPROVAL
        "awaiting_approval"
      when DAG::Node::ERRORED
        "failed"
      when DAG::Node::STOPPED
        "stopped"
      when DAG::Node::FINISHED
        "completed"
      else
        "pending"
      end
    end

    def reduce_phase(execution_node:, activities:)
      active = Array(activities).reject { |activity| terminal_activity_status?(activity.fetch("status")) }
      running = active.select { |activity| activity.fetch("status") == "running" }
      return highest_precedence_phase_for(running) if running.any?

      awaiting = active.select { |activity| activity.fetch("status") == "awaiting_approval" }
      return "authorization" if awaiting.any?

      return earliest_known_phase_for(active) if active.any?

      return "terminal" if Array(activities).any? && Array(activities).all? { |activity| terminal_activity_status?(activity.fetch("status")) }

      case execution_node&.state.to_s
      when DAG::Node::AWAITING_APPROVAL
        "authorization"
      when DAG::Node::RUNNING
        "execution"
      when DAG::Node::PENDING
        "planning"
      else
        "terminal"
      end
    end

    def terminal_activity_status?(status)
      %w[completed failed rejected skipped stopped].include?(status.to_s)
    end

    def pending_activity_status?(status)
      %w[planned pending queued].include?(status.to_s)
    end

    def activity_event?(event)
      DAG::NodeEvent::ACTIVITY_EVENT_KINDS.include?(event.kind.to_s)
    end

    def highest_precedence_phase_for(activities)
      ranked = Array(activities).map { |activity| activity.fetch("phase").to_s }
      ranked.max_by { |phase| phase_precedence.fetch(phase, -1) }
    end

    def earliest_known_phase_for(activities)
      ranked = Array(activities).map { |activity| activity.fetch("phase").to_s }
      ranked.min_by { |phase| phase_precedence.fetch(phase, phase_precedence.length) }
    end

    def phase_precedence
      @phase_precedence ||=
        %w[preflight planning authorization execution finalization terminal]
          .each_with_index
          .to_h
    end

    def diagnostics_for(activity_events, diagnostic_level:)
      return nil unless diagnostic_level == DEBUG_DIAGNOSTIC_LEVEL

      last_event = activity_events.last
      last_payload = last_event&.payload.is_a?(Hash) ? last_event.payload : {}

      {
        "event_count" => activity_events.length,
        "last_event_id" => last_event&.id,
        "last_event_kind" => last_event&.kind.to_s.presence,
        "last_event_data" => last_payload["data"].is_a?(Hash) ? last_payload["data"] : {},
      }.compact
    end

    def diagnostic_level_for(execution_node)
      level =
        if execution_node&.metadata.is_a?(Hash)
          execution_node.metadata.dig("turn_execution", "diagnostic_level")
        end

      level = level.to_s
      level == DEBUG_DIAGNOSTIC_LEVEL ? DEBUG_DIAGNOSTIC_LEVEL : STANDARD_DIAGNOSTIC_LEVEL
    end

    def summary_for(activities)
      visible = Array(activities)

      {
        "activity_count" => visible.length,
        "running_count" => visible.count { |activity| activity["status"] == "running" },
        "awaiting_count" => visible.count { |activity| activity["status"] == "awaiting_approval" },
        "failed_count" => visible.count { |activity| activity["status"] == "failed" },
        "latest_message" => visible.last&.fetch("title", nil),
      }.compact
    end

    def event_cursor_for(turn_nodes)
      event_ids =
        turn_nodes.flat_map do |node|
          node.node_events.filter_map do |event|
            event.id if execution_cursor_event?(node: node, event: event)
          end
        end

      event_ids.max
    end

    def execution_cursor_event?(node:, event:)
      return false if node.nil? || event.nil?

      kind = event.kind.to_s
      return true if node.node_type.to_s == Messages::Task.node_type_key && DAG::NodeEvent::ACTIVITY_EVENT_KINDS.include?(kind)

      assistant_message_node?(node) && kind.in?([DAG::NodeEvent::OUTPUT_DELTA, DAG::NodeEvent::OUTPUT_COMPACTED])
    end

    def started_at_for(turn_nodes)
      times =
        turn_nodes.filter_map do |node|
          node.started_at || node.created_at
        end

      times.min&.iso8601
    end

    def updated_at_for(turn_nodes)
      turn_nodes.map(&:updated_at).compact.max&.iso8601
    end

    def finished_at_for(execution_node:, activities:)
      return nil unless Array(activities).all? { |activity| terminal_activity_status?(activity.fetch("status")) }

      times =
        Array(activities).filter_map do |activity|
          value = activity["finished_at"] || activity["updated_at"]
          Time.iso8601(value) if value.present?
        rescue ArgumentError
          nil
        end
      times << execution_node.finished_at if execution_node&.finished_at
      times.compact.max&.iso8601
    end

    def message_node?(node)
      return false if node.nil?

      node.node_type.to_s.in?(
        [
          Messages::UserMessage.node_type_key,
          Messages::AgentMessage.node_type_key,
          Messages::CharacterMessage.node_type_key,
          Messages::ProductMessage.node_type_key,
        ]
      )
    end

    def assistant_message_node?(node)
      return false if node.nil?

      node.node_type.to_s.in?(
        [
          Messages::AgentMessage.node_type_key,
          Messages::CharacterMessage.node_type_key,
        ]
      )
    end
end
