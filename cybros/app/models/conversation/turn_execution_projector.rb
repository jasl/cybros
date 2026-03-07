class Conversation::TurnExecutionProjector
  PREFLIGHT_TASK_NAMES = %w[compress_input compact_context].freeze
  ASSISTANT_BUBBLE = "assistant_bubble"
  COMPOSER_ONLY = "composer_only"
  STANDARD_DIAGNOSTIC_LEVEL = "standard"

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
    activities = project_activities(turn_nodes)

    {
      "turn_id" => turn_id,
      "anchor_node_id" => anchor&.id,
      "status" => reduce_status(anchor: anchor, activities: activities),
      "phase" => reduce_phase(anchor: anchor, activities: activities),
      "diagnostic_level" => STANDARD_DIAGNOSTIC_LEVEL,
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

    visible_activities = assistant_bubble_activities(execution.fetch("activities", []))
    return nil if visible_activities.empty?

    {
      "status" => execution.fetch("status"),
      "phase" => execution.fetch("phase"),
      "diagnostic_level" => execution.fetch("diagnostic_level"),
      "event_cursor" => execution["event_cursor"],
      "summary" => summary_for(visible_activities),
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

    def project_activities(turn_nodes)
      tasks = turn_nodes.select { |node| node.node_type.to_s == Messages::Task.node_type_key }

      tasks.each_with_index.map do |task, index|
        kind = activity_kind_for(task)
        status = activity_status_for(task)
        {
          "activity_id" => "task:#{task.id}",
          "kind" => kind,
          "status" => status,
          "phase" => activity_phase_for(task, kind: kind, status: status),
          "sequence" => index + 1,
          "title" => activity_title_for(task),
          "source_node_id" => task.id,
          "tool_call_id" => task.body_input["tool_call_id"].to_s.presence,
          "input_preview" => task.body_input["arguments_summary"].to_s.presence,
          "output_preview" => task.body_output_preview["result"].presence,
          "error" => activity_error_for(task, status: status),
          "diagnostics" => nil,
          "started_at" => task.started_at&.iso8601,
          "updated_at" => task.updated_at&.iso8601,
          "finished_at" => task.finished_at&.iso8601,
          "visibility" => activity_visibility_for(kind),
        }.compact
      end
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

    def activity_error_for(task, status:)
      return nil unless status == "failed"

      preview = task.body_output_preview["result"].presence || task.body_output["result"]
      return { "summary" => preview.to_s } if preview.present?

      { "summary" => "task failed" }
    end

    def reduce_status(anchor:, activities:)
      statuses = Array(activities).map { |activity| activity.fetch("status") }
      anchor_state = anchor&.state.to_s

      return "stopped" if anchor_state == DAG::Node::STOPPED || statuses.include?("stopped")
      return "awaiting_approval" if statuses.include?("awaiting_approval")
      return "running" if statuses.include?("running")
      return "pending" if statuses.include?("pending")
      return "failed" if statuses.include?("failed")
      return "completed" if statuses.present? && statuses.all? { |status| terminal_activity_status?(status) }

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
      return active.first.fetch("phase") if active.any?

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
