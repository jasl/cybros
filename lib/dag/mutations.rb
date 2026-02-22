module DAG
  class Mutations
    def initialize(graph:, turn_id: nil)
      @graph = graph
      @turn_id = turn_id
      @executable_pending_nodes_created = false
    end

      def create_node(
      node_type:,
      state:,
      content: nil,
      idempotency_key: nil,
      metadata: {},
      body_input: {},
      body_output: {},
      **attributes
    )
      body_input = normalize_hash(body_input)
      body_output = normalize_hash(body_output)

        if !content.nil?
          body_class = @graph.body_class_for_node_type(node_type)
          destination = body_class.created_content_destination
          unless destination.is_a?(Array) && destination.length == 2
            ValidationError.raise!(
              "invalid created_content_destination=#{destination.inspect} " \
                "for body_class=#{body_class.name}",
              code: "dag.mutations.invalid_created_content_destination_for_body_class",
              details: { destination: destination.inspect, body_class: body_class.name },
            )
          end

        channel, key = destination
        channel = channel.to_sym
        key = key.to_s

          case channel
          when :input
            body_input[key] = content
          when :output
            body_output[key] = content
          else
            ValidationError.raise!(
              "invalid created_content_destination=#{destination.inspect} " \
                "for body_class=#{body_class.name}",
              code: "dag.mutations.invalid_created_content_destination_for_body_class",
              details: { destination: destination.inspect, body_class: body_class.name },
            )
          end
        end

      effective_turn_id = attributes.key?(:turn_id) ? attributes.delete(:turn_id) : @turn_id

      if attributes.key?(:lane)
        lane = attributes.delete(:lane)
        attributes[:lane_id] = lane.is_a?(DAG::Lane) ? lane.id : lane
      end

      lane_id = attributes[:lane_id]
      turn_lane_id =
        if effective_turn_id.present?
          @graph.nodes.active.where(turn_id: effective_turn_id).pick(:lane_id)
        else
          nil
        end

        if lane_id.present?
          if turn_lane_id.present? && turn_lane_id.to_s != lane_id.to_s
            ValidationError.raise!(
              "lane_id conflicts with existing nodes for turn",
              code: "dag.mutations.lane_id_conflicts_with_existing_nodes_for_turn",
              details: { lane_id: lane_id.to_s, turn_lane_id: turn_lane_id.to_s, turn_id: effective_turn_id.to_s },
            )
          end
        else
        lane_id = turn_lane_id || @graph.main_lane.id
        attributes[:lane_id] = lane_id
        end

        if idempotency_key.present?
          ValidationError.raise!(
            "idempotency_key requires turn_id",
            code: "dag.mutations.idempotency_key_requires_turn_id",
          ) if effective_turn_id.blank?

        existing =
          @graph.nodes.active.find_by(
            turn_id: effective_turn_id,
            node_type: node_type,
            idempotency_key: idempotency_key
          )

        if existing
          assert_idempotent_node_match!(
            existing,
            expected_state: state,
            expected_body_input: body_input,
            expected_body_output: body_output
          )

            if existing.lane_id.to_s != lane_id.to_s
              IdempotencyConflictError.raise!(
                "idempotency_key collision with mismatched lane",
                code: "dag.mutations.idempotency_key_collision_with_mismatched_lane",
                details: {
                  idempotency_key: idempotency_key.to_s,
                  expected_lane_id: lane_id.to_s,
                  actual_lane_id: existing.lane_id.to_s,
                },
              )
            end

          if existing.executable? && existing.pending?
            @executable_pending_nodes_created = true
          end

          return existing
        end
        end

      node_attributes = {
        node_type: node_type,
        state: state,
        metadata: metadata,
        idempotency_key: idempotency_key,
        body_input: body_input,
        body_output: body_output,
      }.merge(attributes)

      if effective_turn_id.present?
        node_attributes[:turn_id] = effective_turn_id
      end

      node =
        if idempotency_key.present?
          begin
            DAG::Node.transaction(requires_new: true) do
              @graph.nodes.create!(node_attributes)
            end
            rescue ActiveRecord::RecordNotUnique
              node = @graph.nodes.active.find_by!(
                turn_id: effective_turn_id,
                node_type: node_type,
                idempotency_key: idempotency_key
              )
              if node.lane_id.to_s != lane_id.to_s
                IdempotencyConflictError.raise!(
                  "idempotency_key collision with mismatched lane",
                  code: "dag.mutations.idempotency_key_collision_with_mismatched_lane",
                  details: {
                    idempotency_key: idempotency_key.to_s,
                    expected_lane_id: lane_id.to_s,
                    actual_lane_id: node.lane_id.to_s,
                  },
                )
              end
              node
            end
        else
          @graph.nodes.create!(node_attributes)
        end

      if node.previously_new_record?
        @graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::NODE_CREATED,
          subject: node,
          particulars: { "node_type" => node.node_type, "state" => node.state }
        )
      end

      if node.executable? && node.pending?
        @executable_pending_nodes_created = true
      end

      node
    end

      def create_edge(from_node:, to_node:, edge_type:, metadata: {})
      existing =
        @graph.edges.find_by(
          from_node_id: from_node.id,
          to_node_id: to_node.id,
          edge_type: edge_type
        )
        return existing if existing && existing.compressed_at.nil?
        ValidationError.raise!(
          "edge already exists but is archived",
          code: "dag.mutations.edge_already_exists_but_is_archived",
          details: { from_node_id: from_node.id.to_s, to_node_id: to_node.id.to_s, edge_type: edge_type.to_s },
        ) if existing

      edge =
        begin
          DAG::Edge.transaction(requires_new: true) do
            @graph.edges.create!(
              from_node_id: from_node.id,
              to_node_id: to_node.id,
              edge_type: edge_type,
              metadata: metadata
            )
          end
        rescue ActiveRecord::RecordNotUnique
          @graph.edges.find_by!(from_node_id: from_node.id, to_node_id: to_node.id, edge_type: edge_type)
        end

      if edge.previously_new_record?
        @graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::EDGE_CREATED,
          subject: edge,
          particulars: {
            "edge_type" => edge.edge_type,
            "from_node_id" => edge.from_node_id,
            "to_node_id" => edge.to_node_id,
          }
        )
      end

      edge
    end

      def fork_from!(from_node:, node_type:, state:, content: nil, body_input: {}, body_output: {}, metadata: {})
        assert_node_belongs_to_graph!(from_node)
        OperationNotAllowedError.raise!(
          "cannot fork from compressed nodes",
          code: "dag.mutations.cannot_fork_from_compressed_nodes",
        ) if from_node.compressed_at.present?
        OperationNotAllowedError.raise!(
          "can only fork from terminal nodes",
          code: "dag.mutations.can_only_fork_from_terminal_nodes",
        ) unless from_node.terminal?

      lane =
        @graph.lanes.create!(
          role: DAG::Lane::BRANCH,
          parent_lane_id: from_node.lane_id,
          forked_from_node_id: from_node.id,
          metadata: {}
        )

      node = create_node(
        node_type: node_type,
        state: state,
        content: content,
        metadata: metadata,
        turn_id: nil,
        lane_id: lane.id,
        body_input: body_input,
        body_output: body_output
      )

      create_edge(from_node: from_node, to_node: node, edge_type: DAG::Edge::SEQUENCE, metadata: { "generated_by" => "fork" })
      create_edge(
        from_node: from_node,
        to_node: node,
        edge_type: DAG::Edge::BRANCH,
        metadata: { "branch_kinds" => ["fork"] }
      )

      lane.update!(root_node_id: node.id)
      node.lane = lane

      node
    end

      def merge_lanes!(target_lane:, target_from_node:, source_lanes_and_nodes:, node_type:, metadata: {})
      assert_lane_belongs_to_graph!(target_lane)
      assert_node_belongs_to_graph!(target_from_node)

        OperationNotAllowedError.raise!(
          "cannot merge into archived lane",
          code: "dag.mutations.cannot_merge_into_archived_lane",
        ) if target_lane.archived_at.present?
        ValidationError.raise!(
          "target_from_node must belong to target_lane",
          code: "dag.mutations.target_from_node_must_belong_to_target_lane",
        ) if target_from_node.lane_id != target_lane.id

        sources = Array(source_lanes_and_nodes)
        ValidationError.raise!(
          "source_lanes_and_nodes must not be empty",
          code: "dag.mutations.source_lanes_and_nodes_must_not_be_empty",
        ) if sources.empty?

      source_lane_ids = []
      sources.each do |entry|
        lane = entry.fetch(:lane)
        from_node = entry.fetch(:from_node)

        assert_lane_belongs_to_graph!(lane)
        assert_node_belongs_to_graph!(from_node)

          OperationNotAllowedError.raise!(
            "main lane cannot be merged into another lane",
            code: "dag.mutations.main_lane_cannot_be_merged_into_another_lane",
          ) if lane.role == DAG::Lane::MAIN
          OperationNotAllowedError.raise!(
            "cannot merge a lane into itself",
            code: "dag.mutations.cannot_merge_a_lane_into_itself",
          ) if lane.id == target_lane.id
          ValidationError.raise!(
            "source from_node must belong to lane",
            code: "dag.mutations.source_from_node_must_belong_to_lane",
          ) if from_node.lane_id != lane.id

        source_lane_ids << lane.id
      end

      merge_metadata = normalize_hash(metadata)
      merge_metadata["source_lane_ids"] = source_lane_ids.map(&:to_s).uniq.sort

      node =
        create_node(
          node_type: node_type,
          state: DAG::Node::PENDING,
          metadata: merge_metadata,
          turn_id: nil,
          lane_id: target_lane.id
        )

      create_edge(
        from_node: target_from_node,
        to_node: node,
        edge_type: DAG::Edge::SEQUENCE,
        metadata: { "generated_by" => "merge" }
      )

      sources.each do |entry|
        lane = entry.fetch(:lane)
        from_node = entry.fetch(:from_node)

        create_edge(
          from_node: from_node,
          to_node: node,
          edge_type: DAG::Edge::DEPENDENCY,
          metadata: { "generated_by" => "merge", "source_lane_id" => lane.id }
        )
      end

      node
    end

      def archive_lane!(lane:, mode: :finish, at: Time.current, reason: "lane_archived")
      assert_lane_belongs_to_graph!(lane)

        mode = mode.to_sym
        unless mode.in?([:finish, :cancel])
          ValidationError.raise!(
            "mode must be :finish or :cancel",
            code: "dag.mutations.mode_must_be_finish_or_cancel",
            details: { mode: mode.to_s },
          )
        end

      at = Time.current if at.nil?
      reason = reason.to_s.presence || "lane_archived"

      lane.update!(archived_at: at)
      return lane if mode == :finish

      running_ids = []
      pending_ids = []

      DAG::Node.with_connection do |connection|
        graph_quoted = connection.quote(@graph.id)
        lane_quoted = connection.quote(lane.id)
        now_quoted = connection.quote(at)
        reason_quoted = connection.quote(reason)

        sql_running = <<~SQL
          UPDATE dag_nodes
             SET state = 'stopped',
                 finished_at = #{now_quoted},
                 metadata = dag_nodes.metadata || jsonb_build_object('reason', #{reason_quoted}),
                 updated_at = #{now_quoted}
           WHERE dag_nodes.graph_id = #{graph_quoted}
             AND dag_nodes.compressed_at IS NULL
             AND dag_nodes.lane_id = #{lane_quoted}
             AND dag_nodes.state = 'running'
          RETURNING dag_nodes.id
        SQL

        sql_pending = <<~SQL
          UPDATE dag_nodes
             SET state = 'stopped',
                 finished_at = #{now_quoted},
                 metadata = dag_nodes.metadata || jsonb_build_object('reason', #{reason_quoted}),
                 updated_at = #{now_quoted}
           WHERE dag_nodes.graph_id = #{graph_quoted}
             AND dag_nodes.compressed_at IS NULL
             AND dag_nodes.lane_id = #{lane_quoted}
             AND dag_nodes.state = 'pending'
          RETURNING dag_nodes.id
        SQL

        running_ids = connection.select_values(sql_running)
        pending_ids = connection.select_values(sql_pending)
      end

      running_ids.each do |node_id|
        @graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
          subject_type: "DAG::Node",
          subject_id: node_id,
          particulars: { "from" => "running", "to" => "stopped" }
        )
      end

      pending_ids.each do |node_id|
        @graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
          subject_type: "DAG::Node",
          subject_id: node_id,
          particulars: { "from" => "pending", "to" => "stopped" }
        )
      end

      lane
    end

      def retry_replace!(node:)
      old = locked_active_node!(node)
      now = Time.current

        unless old.body.retriable?
          OperationNotAllowedError.raise!(
            "can only retry retriable nodes",
            code: "dag.mutations.can_only_retry_retriable_nodes",
          )
        end

        unless [DAG::Node::ERRORED, DAG::Node::REJECTED, DAG::Node::STOPPED].include?(old.state)
          OperationNotAllowedError.raise!(
            "can only retry errored, rejected, or stopped nodes",
            code: "dag.mutations.can_only_retry_errored_rejected_or_stopped_nodes",
          )
        end

        descendant_ids = active_causal_descendant_ids_for(old.id) - [old.id]
        if @graph.nodes.where(id: descendant_ids, compressed_at: nil).where.not(state: DAG::Node::PENDING).exists?
          OperationNotAllowedError.raise!(
            "cannot retry when downstream nodes are not pending",
            code: "dag.mutations.cannot_retry_when_downstream_nodes_are_not_pending",
          )
        end

      outgoing_blocking_edges = active_outgoing_blocking_edges_from(old.id)
      if outgoing_blocking_edges.any?
          child_states = @graph.nodes.where(id: outgoing_blocking_edges.map(&:to_node_id)).pluck(:id, :state).to_h
          unless outgoing_blocking_edges.all? { |edge| child_states[edge.to_node_id] == DAG::Node::PENDING }
            OperationNotAllowedError.raise!(
              "can only retry when all active blocking children are pending",
              code: "dag.mutations.can_only_retry_when_all_active_blocking_children_are_pending",
            )
          end
      end

      attempt = old.metadata.fetch("attempt", 1).to_i + 1
      body_input = old.body.input_for_retry
      retry_metadata =
        old.metadata
          .except("error", "reason", "blocked_by", "usage", "output_stats", "timing", "worker")
          .merge("attempt" => attempt)

      state =
        if old.rejected? && old.metadata["reason"].to_s == "approval_denied"
          DAG::Node::AWAITING_APPROVAL
        else
          DAG::Node::PENDING
        end

      new_node = create_node(
        node_type: old.node_type,
        state: state,
        metadata: retry_metadata,
        retry_of_id: old.id,
        turn_id: old.turn_id,
        lane_id: old.lane_id,
        version_set_id: old.version_set_id,
        body_input: body_input,
      )

      copy_incoming_blocking_edges!(from_node_id: old.id, to_node_id: new_node.id)

      outgoing_blocking_edges.each do |edge|
        create_edge_by_id(
          from_node_id: new_node.id,
          to_node_id: edge.to_node_id,
          edge_type: edge.edge_type,
          metadata: edge.metadata
        )
      end

      create_edge_by_id(
        from_node_id: old.id,
        to_node_id: new_node.id,
        edge_type: DAG::Edge::BRANCH,
        metadata: { "branch_kinds" => ["retry"] }
      )

      archived_edge_ids = archive_nodes_and_incident_edges!(node_ids: [old.id], compressed_by_id: new_node.id, now: now)

      @graph.emit_event(
        event_type: DAG::GraphHooks::EventTypes::NODE_REPLACED,
        subject: new_node,
        particulars: {
          "kind" => "retry",
          "old_id" => old.id,
          "new_id" => new_node.id,
          "archived_node_ids" => [old.id],
          "archived_edge_ids" => archived_edge_ids,
        }
      )

      new_node
    end

      def rerun_replace!(node:, metadata_patch: {}, body_input_patch: {})
      old = locked_active_node!(node)
      now = Time.current

        unless old.body.rerunnable?
          OperationNotAllowedError.raise!(
            "can only rerun rerunnable nodes",
            code: "dag.mutations.can_only_rerun_rerunnable_nodes",
          )
        end

        unless old.state == DAG::Node::FINISHED
          OperationNotAllowedError.raise!(
            "can only rerun finished nodes",
            code: "dag.mutations.can_only_rerun_finished_nodes",
          )
        end

        outgoing_blocking_edges = active_outgoing_blocking_edges_from(old.id)
        if outgoing_blocking_edges.any?
          OperationNotAllowedError.raise!(
            "can only rerun leaf nodes",
            code: "dag.mutations.can_only_rerun_leaf_nodes",
          )
        end

      metadata_patch = normalize_hash(metadata_patch)
      body_input_patch = normalize_hash(body_input_patch)

      new_node = create_node(
        node_type: old.node_type,
        state: DAG::Node::PENDING,
        metadata:
          old.metadata
            .except("error", "reason", "blocked_by", "usage", "output_stats", "timing", "worker")
            .merge(metadata_patch),
        turn_id: old.turn_id,
        lane_id: old.lane_id,
        version_set_id: old.version_set_id,
        body_input: old.body.input_for_retry.deep_merge(body_input_patch),
      )

      copy_incoming_blocking_edges!(from_node_id: old.id, to_node_id: new_node.id)

      create_edge_by_id(
        from_node_id: old.id,
        to_node_id: new_node.id,
        edge_type: DAG::Edge::BRANCH,
        metadata: { "branch_kinds" => ["rerun"] }
      )

      archived_edge_ids = archive_nodes_and_incident_edges!(node_ids: [old.id], compressed_by_id: new_node.id, now: now)

      @graph.emit_event(
        event_type: DAG::GraphHooks::EventTypes::NODE_REPLACED,
        subject: new_node,
        particulars: {
          "kind" => "rerun",
          "old_id" => old.id,
          "new_id" => new_node.id,
          "archived_node_ids" => [old.id],
          "archived_edge_ids" => archived_edge_ids,
        }
      )

      new_node
    end

      def adopt_version!(node:)
      target = locked_node!(node)
      now = Time.current

        if @graph.nodes.active.where(state: DAG::Node::RUNNING).exists?
          OperationNotAllowedError.raise!(
            "cannot adopt version while graph has running nodes",
            code: "dag.mutations.cannot_adopt_version_while_graph_has_running_nodes",
          )
        end

        unless target.finished?
          OperationNotAllowedError.raise!(
            "can only adopt finished nodes",
            code: "dag.mutations.can_only_adopt_finished_nodes",
          )
        end

        if @graph.edges.where(from_node_id: target.id, edge_type: DAG::Edge::BLOCKING_EDGE_TYPES).exists?
          OperationNotAllowedError.raise!(
            "can only adopt leaf nodes",
            code: "dag.mutations.can_only_adopt_leaf_nodes",
          )
        end

        active_versions = @graph.nodes.active.where(version_set_id: target.version_set_id).lock.to_a
        if active_versions.empty? && target.compressed_at.present?
          OperationNotAllowedError.raise!(
            "cannot adopt version when no active version exists",
            code: "dag.mutations.cannot_adopt_version_when_no_active_version_exists",
          )
        end

        if active_versions.any? && active_versions.any? { |node| node.turn_id != target.turn_id || node.lane_id != target.lane_id }
          ValidationError.raise!(
            "version_set_id must not span multiple turns or lanes",
            code: "dag.mutations.version_set_id_must_not_span_multiple_turns_or_lanes",
          )
        end

      nodes_to_archive = active_versions.reject { |node| node.id == target.id }.map(&:id)

      if nodes_to_archive.any?
        archive_nodes_and_incident_edges!(node_ids: nodes_to_archive, compressed_by_id: target.id, now: now)
      end

      if target.compressed_at.present?
        @graph.nodes.where(id: target.id).update_all(
          compressed_at: nil,
          compressed_by_id: nil,
          updated_at: now
        )
      end

      active_node_ids = @graph.nodes.active.select(:id)

        unless @graph.edges.where(to_node_id: target.id, edge_type: DAG::Edge::BLOCKING_EDGE_TYPES, from_node_id: active_node_ids).exists?
          OperationNotAllowedError.raise!(
            "cannot adopt version without active incoming edges",
            code: "dag.mutations.cannot_adopt_version_without_active_incoming_edges",
          )
        end

      @graph.edges.where(to_node_id: target.id, edge_type: DAG::Edge::BLOCKING_EDGE_TYPES, from_node_id: active_node_ids).update_all(
        compressed_at: nil,
        updated_at: now
      )

        if active_outgoing_blocking_edges_from(target.id).any?
          OperationNotAllowedError.raise!(
            "cannot adopt non-leaf nodes",
            code: "dag.mutations.cannot_adopt_non_leaf_nodes",
          )
        end

      cleanup_invalid_leaves_in_turn!(lane_id: target.lane_id, turn_id: target.turn_id, compressed_by_id: target.id, now: now)

      DAG::TurnAnchorMaintenance.refresh_for_turn_ids!(
        graph: @graph,
        lane_id: target.lane_id,
        turn_ids: [target.turn_id]
      )

      @graph.nodes.reload.find(target.id)
    end

      def edit_replace!(node:, new_input:)
      old = locked_active_node!(node)
      now = Time.current

        unless old.body.editable?
          OperationNotAllowedError.raise!(
            "can only edit editable nodes",
            code: "dag.mutations.can_only_edit_editable_nodes",
          )
        end

        unless old.state == DAG::Node::FINISHED
          OperationNotAllowedError.raise!(
            "can only edit finished nodes",
            code: "dag.mutations.can_only_edit_finished_nodes",
          )
        end

        descendant_ids = active_causal_descendant_ids_for(old.id) - [old.id]
        if @graph.nodes.where(id: descendant_ids, compressed_at: nil, state: [DAG::Node::PENDING, DAG::Node::RUNNING]).exists?
          OperationNotAllowedError.raise!(
            "cannot edit when downstream nodes are pending or running",
            code: "dag.mutations.cannot_edit_when_downstream_nodes_are_pending_or_running",
          )
        end

      new_body_input = old.body.input_for_retry.deep_merge(normalize_hash(new_input))

      new_node = create_node(
        node_type: old.node_type,
        state: DAG::Node::FINISHED,
        metadata: old.metadata.except("error", "reason", "blocked_by", "usage", "output_stats", "timing", "worker"),
        turn_id: old.turn_id,
        lane_id: old.lane_id,
        version_set_id: old.version_set_id,
        body_input: new_body_input,
        finished_at: now
      )

      copy_incoming_blocking_edges!(from_node_id: old.id, to_node_id: new_node.id)

      create_edge_by_id(
        from_node_id: old.id,
        to_node_id: new_node.id,
        edge_type: DAG::Edge::BRANCH,
        metadata: { "branch_kinds" => ["edit"] }
      )

      nodes_to_archive = active_causal_descendant_ids_for(old.id)
      archived_edge_ids =
        archive_nodes_and_incident_edges!(node_ids: nodes_to_archive, compressed_by_id: new_node.id, now: now)

      @graph.emit_event(
        event_type: DAG::GraphHooks::EventTypes::NODE_REPLACED,
        subject: new_node,
        particulars: {
          "kind" => "edit",
          "old_id" => old.id,
          "new_id" => new_node.id,
          "archived_node_ids" => nodes_to_archive,
          "archived_edge_ids" => archived_edge_ids,
        }
      )

      new_node
    end

    def executable_pending_nodes_created?
      @executable_pending_nodes_created
    end

    private

        def assert_node_belongs_to_graph!(node)
          return if node.graph_id == @graph.id

          ValidationError.raise!(
            "node must belong to the same graph",
            code: "dag.mutations.node_must_belong_to_the_same_graph",
          )
        end

        def assert_lane_belongs_to_graph!(lane)
          return if lane.graph_id == @graph.id

          ValidationError.raise!(
            "lane must belong to the same graph",
            code: "dag.mutations.lane_must_belong_to_the_same_graph",
          )
        end

      def locked_active_node!(node_or_id)
        node_id = node_or_id.is_a?(DAG::Node) ? node_or_id.id : node_or_id
        @graph.nodes.where(compressed_at: nil).lock.find(node_id)
      end

      def locked_node!(node_or_id)
        node_id = node_or_id.is_a?(DAG::Node) ? node_or_id.id : node_or_id
        @graph.nodes.lock.find(node_id)
      end

      def active_causal_descendant_ids_for(node_id)
        DAG::Node.with_connection do |connection|
          node_quoted = connection.quote(node_id)
          graph_quoted = connection.quote(@graph.id)

          sql = <<~SQL
            WITH RECURSIVE descendants(node_id) AS (
              SELECT #{node_quoted}::uuid
              UNION
              SELECT e.to_node_id
              FROM dag_edges e
              JOIN descendants d ON e.from_node_id = d.node_id
              JOIN dag_nodes n ON n.id = e.to_node_id
              WHERE e.graph_id = #{graph_quoted}
                AND e.compressed_at IS NULL
                AND e.edge_type IN ('sequence', 'dependency')
                AND n.compressed_at IS NULL
            )
            SELECT DISTINCT node_id FROM descendants
          SQL

          connection.select_values(sql)
        end
      end

      def active_outgoing_blocking_edges_from(node_id)
        @graph.edges.active
          .where(from_node_id: node_id, edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)
          .where(to_node_id: @graph.nodes.active.select(:id))
          .to_a
      end

      def copy_incoming_blocking_edges!(from_node_id:, to_node_id:)
        @graph.edges.active
          .where(to_node_id: from_node_id, edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)
          .find_each do |edge|
            create_edge_by_id(
              from_node_id: edge.from_node_id,
              to_node_id: to_node_id,
              edge_type: edge.edge_type,
              metadata: edge.metadata
            )
          end
      end

        def create_edge_by_id(from_node_id:, to_node_id:, edge_type:, metadata:)
          existing = @graph.edges.find_by(from_node_id: from_node_id, to_node_id: to_node_id, edge_type: edge_type)
        return existing if existing && existing.compressed_at.nil?
        ValidationError.raise!(
          "edge already exists but is archived",
          code: "dag.mutations.edge_already_exists_but_is_archived",
          details: { from_node_id: from_node_id.to_s, to_node_id: to_node_id.to_s, edge_type: edge_type.to_s },
        ) if existing

        edge =
          begin
            DAG::Edge.transaction(requires_new: true) do
              @graph.edges.create!(
                from_node_id: from_node_id,
                to_node_id: to_node_id,
                edge_type: edge_type,
                metadata: metadata
              )
            end
          rescue ActiveRecord::RecordNotUnique
            @graph.edges.find_by!(from_node_id: from_node_id, to_node_id: to_node_id, edge_type: edge_type)
          end

        if edge.previously_new_record?
          @graph.emit_event(
            event_type: DAG::GraphHooks::EventTypes::EDGE_CREATED,
            subject: edge,
            particulars: {
              "edge_type" => edge.edge_type,
              "from_node_id" => edge.from_node_id,
              "to_node_id" => edge.to_node_id,
            }
          )
        end

        edge
      end

      def archive_nodes_and_incident_edges!(node_ids:, compressed_by_id:, now:)
        node_ids = Array(node_ids).map(&:to_s).uniq
        return [] if node_ids.empty?

        turn_rows =
          @graph.nodes
            .where(id: node_ids)
            .pluck(:lane_id, :turn_id)

        edge_ids = @graph.edges.active
          .where("from_node_id IN (?) OR to_node_id IN (?)", node_ids, node_ids)
          .pluck(:id)

        @graph.nodes.where(id: node_ids).update_all(
          compressed_at: now,
          compressed_by_id: compressed_by_id,
          updated_at: now
        )

        @graph.edges.where(id: edge_ids).update_all(compressed_at: now, updated_at: now)

        turn_rows
          .group_by { |(lane_id, _turn_id)| lane_id.to_s }
          .each do |lane_id, rows|
            turn_ids = rows.map { |(_lane_id, turn_id)| turn_id.to_s }.uniq
            DAG::TurnAnchorMaintenance.refresh_for_turn_ids!(
              graph: @graph,
              lane_id: lane_id,
              turn_ids: turn_ids
            )
          end

        edge_ids
      end

      def normalize_hash(hash)
        if hash.is_a?(Hash)
          hash.deep_stringify_keys
        else
          {}
        end
      end

      def cleanup_invalid_leaves_in_turn!(lane_id:, turn_id:, compressed_by_id:, now:)
        leaf_terminal_types = @graph.leaf_terminal_node_types
        turn_anchor_types = @graph.turn_anchor_node_types

        loop do
          leaves =
            @graph.leaf_nodes
              .where(lane_id: lane_id, turn_id: turn_id)
              .select(:id, :node_type, :state)
              .to_a

          invalid_leaves =
            leaves.select do |leaf|
              !leaf_terminal_types.include?(leaf.node_type.to_s) &&
                !leaf.pending? &&
                !leaf.awaiting_approval? &&
                !leaf.running?
            end

          break if invalid_leaves.empty?

          if invalid_leaves.any? { |leaf| turn_anchor_types.include?(leaf.node_type.to_s) }
                OperationNotAllowedError.raise!(
                  "cannot adopt version because it would invalidate turn anchors",
                  code: "dag.mutations.cannot_adopt_version_because_it_would_invalidate_turn_anchors",
                  details: { lane_id: lane_id.to_s, turn_id: turn_id.to_s },
                )
          end

          archive_nodes_and_incident_edges!(
            node_ids: invalid_leaves.map(&:id),
            compressed_by_id: compressed_by_id,
            now: now
          )
        end
      end

        def assert_idempotent_node_match!(node, expected_state:, expected_body_input:, expected_body_output:)
          if node.state != expected_state.to_s
            IdempotencyConflictError.raise!(
              "idempotency_key collision with mismatched state",
              code: "dag.mutations.idempotency_key_collision_with_mismatched_state",
              details: { idempotency_key: node.idempotency_key.to_s, expected_state: expected_state.to_s, actual_state: node.state.to_s },
            )
          end

        actual_body_input = node.body&.input.is_a?(Hash) ? node.body.input : {}
        actual_body_output = node.body&.output.is_a?(Hash) ? node.body.output : {}

          if actual_body_input != expected_body_input || actual_body_output != expected_body_output
            IdempotencyConflictError.raise!(
              "idempotency_key collision with mismatched body I/O",
              code: "dag.mutations.idempotency_key_collision_with_mismatched_body_i_o",
              details: { idempotency_key: node.idempotency_key.to_s },
            )
          end
        end
  end
end
