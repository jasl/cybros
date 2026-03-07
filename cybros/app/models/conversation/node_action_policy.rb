class Conversation::NodeActionPolicy
  ACTIONS = %w[retry regenerate swipe branch delete restore exclude include translate stop edit].freeze
  CAPABILITIES = %w[execute].freeze

  def initialize(conversation:, node:)
    @conversation = conversation
    @node = node
  end

  def to_h
    {
      "actions" => action_entries,
      "capabilities" => capability_entries,
    }
  end

  private

    attr_reader :conversation, :node

    def action_entries
      {
        "retry" => retry_entry,
        "regenerate" => regenerate_entry,
        "swipe" => swipe_entry,
        "branch" => branch_entry,
        "delete" => delete_entry,
        "restore" => restore_entry,
        "exclude" => exclude_entry,
        "include" => include_entry,
        "translate" => translate_entry,
        "stop" => stop_entry,
        "edit" => edit_entry,
      }
    end

    def capability_entries
      {
        "execute" => entry(supported: executable?, available: executable_available?),
      }
    end

    def retry_entry
      supported = node.body&.retriable? == true
      return unsupported_entry unless supported
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "deleted") if node.deleted?

      unless node.errored? || node.stopped?
        return unavailable_entry(reason: "not_retryable_state")
      end

      return unavailable_entry(reason: "not_retryable_now") unless node.can_retry?
      return unavailable_entry(reason: "retry_limit_reached") if retry_depth >= 5
      return unavailable_entry(reason: "retry_already_queued") if retry_already_queued?
      return unavailable_entry(reason: "missing_parent") unless sequence_parent_id.present?

      entry(supported: true, available: true, mode: "direct")
    end

    def regenerate_entry
      supported = node.body&.rerunnable? == true
      return unsupported_entry unless supported
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "deleted") if node.deleted?
      return unavailable_entry(reason: "not_terminal") unless node.terminal?
      return unavailable_entry(reason: "not_finished") unless node.finished?

      if tail_agent?
        return unavailable_entry(mode: "in_place", reason: "not_rerunnable_now") unless node.can_rerun?

        return entry(supported: true, available: true, mode: "in_place")
      end

      return unavailable_entry(mode: "branch", reason: "not_branchable") unless branch_supported?

      entry(supported: true, available: true, mode: "branch")
    end

    def swipe_entry
      supported = node.body&.swipable? == true
      return unsupported_entry unless supported
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "deleted") if node.deleted?
      return unavailable_entry(reason: "not_tail") unless tail_agent?
      return unavailable_entry(reason: "not_finished") unless node.finished?

      entry(supported: true, available: true)
    end

    def branch_entry
      return unsupported_entry unless branch_supported?
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "deleted") if node.deleted?
      return unavailable_entry(reason: "not_forkable_now") unless node.can_fork?

      entry(supported: true, available: true)
    end

    def delete_entry
      supported = node.body&.deletable? == true
      return unsupported_entry unless supported
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "already_deleted") if node.deleted?
      return unavailable_entry(reason: "fork_point") if fork_point?

      entry(supported: true, available: true, mode: delete_mode)
    end

    def restore_entry
      supported = node.body&.deletable? == true
      return unsupported_entry unless supported
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "not_deleted") unless node.deleted?

      mode = node.can_restore? ? "immediate" : "deferred"
      entry(supported: true, available: true, mode: mode)
    end

    def exclude_entry
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "deleted") if node.deleted?
      return unavailable_entry(reason: "already_excluded") if node.context_excluded?

      mode = node.can_exclude_from_context? ? "immediate" : "deferred"
      entry(supported: true, available: true, mode: mode)
    end

    def include_entry
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "deleted") if node.deleted?
      return unavailable_entry(reason: "not_excluded") unless node.context_excluded?

      mode = node.can_include_in_context? ? "immediate" : "deferred"
      entry(supported: true, available: true, mode: mode)
    end

    def translate_entry
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "deleted") if node.deleted?

      entry(supported: true, available: true)
    end

    def stop_entry
      supported = executable?
      return unsupported_entry unless supported
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "not_running") unless stoppable_state?

      entry(supported: true, available: true)
    end

    def edit_entry
      supported = node.body&.editable? == true
      return unsupported_entry unless supported
      return unavailable_entry(reason: "wrong_lane") unless in_chat_lane?
      return unavailable_entry(reason: "deleted") if node.deleted?
      return unavailable_entry(reason: "not_editable_now") unless node.can_edit?

      entry(supported: true, available: true)
    end

    def in_chat_lane?
      node.lane_id.to_s == conversation.chat_lane.id.to_s
    end

    def tail_agent?
      return false unless node.node_type.to_s == Messages::AgentMessage.node_type_key

      conversation.chat_head_node_id(node_type: Messages::AgentMessage.node_type_key) == node.id.to_s
    end

    def retry_depth
      depth = 0
      trace_id = node.id.to_s

      while (source_id = retry_source_id_for(trace_id))
        depth += 1
        trace_id = source_id.to_s
      end

      depth
    end

    def retry_already_queued?
      existing_retry =
        conversation.root_graph.nodes
          .where(node_type: Messages::AgentMessage.node_type_key, compressed_at: nil)
          .where(
            "retry_of_id = :node_id OR metadata ->> 'retry_of_node_id' = :node_id_text",
            node_id: node.id,
            node_id_text: node.id.to_s,
          )
          .order(:id)
          .last

      existing_retry.present? && !existing_retry.terminal?
    end

    def sequence_parent_id
      conversation.root_graph.edges.active
        .where(edge_type: DAG::Edge::SEQUENCE, to_node_id: node.id)
        .order(:id)
        .pick(:from_node_id)
    end

    def branch_supported?
      node.body&.forkable? == true
    end

    def fork_point?
      conversation.send(:fork_point_node?, node)
    end

    def delete_mode
      return "immediate" if node.can_soft_delete?

      if !node.terminal? && other_running_nodes_excluding_self?
        "deferred"
      elsif !node.terminal?
        "immediate"
      else
        "deferred"
      end
    end

    def executable?
      node.executable?
    end

    def retry_source_id_for(node_id)
      candidate = conversation.root_graph.nodes.find_by(id: node_id)
      return nil if candidate.nil?

      candidate.retry_of_id || candidate.metadata&.dig("retry_of_node_id")
    end

    def executable_available?
      return false unless executable?
      return false if node.deleted?
      return false if node.compressed_at.present?

      [DAG::Node::PENDING, DAG::Node::AWAITING_APPROVAL, DAG::Node::RUNNING].include?(node.state)
    end

    def other_running_nodes_excluding_self?
      conversation.root_graph.nodes.active.where.not(id: node.id).where(state: DAG::Node::RUNNING).exists?
    end

    def stoppable_state?
      [DAG::Node::PENDING, DAG::Node::AWAITING_APPROVAL, DAG::Node::RUNNING].include?(node.state)
    end

    def entry(supported:, available:, mode: nil, reason: nil)
      out = {
        "supported" => supported == true,
        "available" => available == true,
      }
      out["mode"] = mode.to_s if mode.present?
      out["reason"] = reason.to_s if reason.present?
      out
    end

    def unavailable_entry(mode: nil, reason:)
      entry(supported: true, available: false, mode: mode, reason: reason)
    end

    def unsupported_entry
      entry(supported: false, available: false, reason: "unsupported")
    end
end
