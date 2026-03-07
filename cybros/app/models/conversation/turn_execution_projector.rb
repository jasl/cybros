class Conversation::TurnExecutionProjector
  PREFLIGHT_TASK_NAMES = %w[compress_input compact_context].freeze
  ASSISTANT_BUBBLE = "assistant_bubble"
  COMPOSER_ONLY = "composer_only"
  STANDARD_DIAGNOSTIC_LEVEL = "standard"
  DEBUG_DIAGNOSTIC_LEVEL = "debug"

  def initialize(conversation:)
    @conversation = conversation
    @graph = conversation.root_graph
    @lane_id = conversation.chat_lane.id
  end

  def turn_execution_for_turn_id(turn_id)
    turn_id = turn_id.to_s
    return nil if turn_id.blank?

    turn_nodes = scoped_nodes.where(turn_id: turn_id).includes(:body, :node_events).order(:id).to_a
    return nil if turn_nodes.empty?

    anchor = anchor_node_for(turn_nodes)
    diagnostic_level = diagnostic_level_for(anchor)
    activities = project_activities(turn_nodes, diagnostic_level: diagnostic_level)

    {
      "turn_id" => turn_id,
      "anchor_node_id" => anchor&.id,
      "status" => reduce_status(anchor: anchor, activities: activities),
      "phase" => reduce_phase(anchor: anchor, activities: activities),
      "diagnostic_level" => diagnostic_level,
      "event_cursor" => event_cursor_for(turn_nodes),
      "started_at" => started_at_for(turn_nodes),
      "updated_at" => updated_at_for(turn_nodes),
      "finished_at" => finished_at_for(anchor: anchor, activities: activities),
      "summary" => summary_for(activities),
      "activities" => activities,
    }
  end

  def turn_execution_for_node_id(node_id)
    node = scoped_nodes.find_by(id: node_id.to_s)
    return nil if node.nil?

    turn_execution_for_turn_id(node.turn_id)
  end

    def run_state_for_node_id(node_id)
      node = scoped_nodes.find_by(id: node_id.to_s)
      return nil unless assistant_message_node?(node)

      execution = turn_execution_for_turn_id(node.turn_id)
      return nil unless execution.is_a?(Hash)

      all_activities = Array(execution.fetch("activities", []))
      visible_activities = assistant_bubble_activities(all_activities)
      hidden_summary = summary_for(all_activities - visible_activities)
      hidden_notice = hidden_summary.fetch("failed_count", 0).to_i.positive? || hidden_summary.fetch("awaiting_count", 0).to_i.positive?

      return nil if visible_activities.empty? && !hidden_notice

      {
        "status" => execution.fetch("status"),
        "phase" => execution.fetch("phase"),
        "diagnostic_level" => execution.fetch("diagnostic_level"),
        "event_cursor" => execution["event_cursor"],
        "summary" => summary_for(visible_activities),
        "hidden_summary" => hidden_summary,
        "activities" => visible_activities,
      }
    end

  private

    def scoped_nodes
      @graph.nodes.active.where(lane_id: @lane_id)
    end

    def anchor_node_for(turn_nodes)
      message_nodes = turn_nodes.select { |node| message_node?(node) }
      return message_nodes.last if message_nodes.any?

      turn_nodes.last
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

      kind = last_payload["kind"].to_s.presence || activity_kind_for(task)
      status = last_payload["status"].to_s.presence || activity_status_for(task)

      {
        "activity_id" => last_payload["activity_id"].to_s.presence || "task:#{task.id}",
        "kind" => kind,
        "status" => status,
        "phase" => last_payload["phase"].to_s.presence || activity_phase_for(task, kind: kind, status: status),
        "sequence" => Integer(last_payload["sequence"], exception: false) || sequence_fallback,
        "title" => activity_title_for(task),
        "source_node_id" => last_payload["source_node_id"].to_s.presence || task.id,
        "tool_call_id" => task.body_input["tool_call_id"].to_s.presence,
        "input_preview" => task.body_input["arguments_summary"].to_s.presence,
        "output_preview" => task.body_output_preview["result"].presence,
        "error" => activity_error_for(task, status: status, last_payload: last_payload),
        "last_event_id" => last_event&.id,
        "diagnostics" => diagnostics_for(activity_events, diagnostic_level: diagnostic_level),
        "started_at" => task.started_at&.iso8601,
        "updated_at" => task.updated_at&.iso8601,
        "finished_at" => task.finished_at&.iso8601,
        "visibility" => activity_visibility_for(kind),
      }.compact
    end

    def assistant_bubble_activities(activities)
      Array(activities).select { |activity| activity["visibility"] == ASSISTANT_BUBBLE }
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

    def activity_title_for(task)
      input = task.body_input
      input["name"].to_s.presence ||
        input["requested_name"].to_s.presence ||
        input["resolved_name"].to_s.presence ||
        task.node_type.to_s
    end

    def activity_error_for(task, status:, last_payload: {})
      return nil unless status == "failed"

      event_error = last_payload.fetch("data", {}).is_a?(Hash) ? last_payload.fetch("data", {}).fetch("error", nil) : nil
      return { "summary" => event_error.to_s } if event_error.present?

      preview = task.body_output_preview["result"].presence || task.body_output["result"]
      return { "summary" => preview.to_s } if preview.present?

      { "summary" => "task failed" }
    end

    def reduce_status(anchor:, activities:)
      statuses = Array(activities).map { |activity| activity.fetch("status") }
      anchor_state = anchor&.state.to_s

      return "stopped" if anchor_state == DAG::Node::STOPPED || statuses.include?("stopped")
      return "running" if statuses.include?("running")
      return "awaiting_approval" if statuses.include?("awaiting_approval")
      return "failed" if statuses.include?("failed")
      return "completed" if statuses.present? && statuses.all? { |status| terminal_activity_status?(status) }
      return "pending" if statuses.any? { |status| pending_activity_status?(status) }

      case anchor_state
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

    def reduce_phase(anchor:, activities:)
      active = Array(activities).reject { |activity| terminal_activity_status?(activity.fetch("status")) }
      running = active.select { |activity| activity.fetch("status") == "running" }
      return highest_precedence_phase_for(running) if running.any?

      awaiting = active.select { |activity| activity.fetch("status") == "awaiting_approval" }
      return "authorization" if awaiting.any?

      return earliest_known_phase_for(active) if active.any?

      return "terminal" if Array(activities).any? && Array(activities).all? { |activity| terminal_activity_status?(activity.fetch("status")) }

      case anchor&.state.to_s
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

    def diagnostic_level_for(anchor)
      level =
        if anchor&.metadata.is_a?(Hash)
          anchor.metadata.dig("turn_execution", "diagnostic_level")
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
          node.node_events.map(&:id)
        end

      event_ids.max
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

    def finished_at_for(anchor:, activities:)
      return nil unless Array(activities).all? { |activity| terminal_activity_status?(activity.fetch("status")) }

      times =
        Array(activities).filter_map do |activity|
          value = activity["finished_at"] || activity["updated_at"]
          Time.iso8601(value) if value.present?
        rescue ArgumentError
          nil
        end
      times << anchor.finished_at if anchor&.finished_at
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
