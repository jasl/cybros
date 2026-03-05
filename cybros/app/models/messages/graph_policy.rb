module Messages
  class GraphPolicy < DAG::GraphPolicy
    def initialize(conversation:)
      @conversation = conversation
    end

    def assert_allowed!(operation:, graph:, subject: nil, details: {})
      _ = graph
      _ = @conversation

      op = operation.to_sym
      node = subject
      action = (details.is_a?(Hash) ? (details[:action] || details["action"]) : nil).to_s

      case op
      when :fork_from
        deny!(
          "cannot fork from deleted node",
          code: "dag.policy.cannot_fork_from_deleted_node",
          details: { node_id: node&.id.to_s, node_type: node&.node_type.to_s }
        ) if node&.deleted?

        allow = node&.body&.forkable? == true
        deny!(
          "node type is not forkable",
          code: "dag.policy.node_type_is_not_forkable",
          details: { node_id: node&.id.to_s, node_type: node&.node_type.to_s }
        ) unless allow

      when :adopt_version
        deny!(
          "cannot swipe deleted node",
          code: "dag.policy.cannot_swipe_deleted_node",
          details: { node_id: node&.id.to_s, node_type: node&.node_type.to_s }
        ) if node&.deleted?

        allow = node&.body&.swipable? == true
        deny!(
          "node type is not swipable",
          code: "dag.policy.node_type_is_not_swipable",
          details: { node_id: node&.id.to_s, node_type: node&.node_type.to_s }
        ) unless allow

      when :rerun_replace
        deny!(
          "cannot rerun deleted node",
          code: "dag.policy.cannot_rerun_deleted_node",
          details: { node_id: node&.id.to_s, node_type: node&.node_type.to_s }
        ) if node&.deleted?

        allow = node&.body&.rerunnable? == true
        deny!(
          "node type is not rerunnable",
          code: "dag.policy.node_type_is_not_rerunnable",
          details: { node_id: node&.id.to_s, node_type: node&.node_type.to_s }
        ) unless allow

      when :edit_replace
        deny!(
          "cannot edit deleted node",
          code: "dag.policy.cannot_edit_deleted_node",
          details: { node_id: node&.id.to_s, node_type: node&.node_type.to_s }
        ) if node&.deleted?

        allow = node&.body&.editable? == true
        deny!(
          "node type is not editable",
          code: "dag.policy.node_type_is_not_editable",
          details: { node_id: node&.id.to_s, node_type: node&.node_type.to_s }
        ) unless allow

      when :visibility_strict, :visibility_deferred
        if action.in?(%w[soft_delete restore])
          allow = node&.body&.deletable? == true
          deny!(
            "node type is not deletable",
            code: "dag.policy.node_type_is_not_deletable",
            details: { action: action, node_id: node&.id.to_s, node_type: node&.node_type.to_s }
          ) unless allow
        end
      end

      true
    end
  end
end

