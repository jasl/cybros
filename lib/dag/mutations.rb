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
        body_class = @graph.policy.body_class_for_node_type(node_type)
        destination = body_class.created_content_destination
        unless destination.is_a?(Array) && destination.length == 2
          raise ArgumentError,
                "invalid created_content_destination=#{destination.inspect} " \
                "for body_class=#{body_class.name}"
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
          raise ArgumentError,
                "invalid created_content_destination=#{destination.inspect} " \
                "for body_class=#{body_class.name}"
        end
      end

      effective_turn_id = attributes.key?(:turn_id) ? attributes.delete(:turn_id) : @turn_id

      if idempotency_key.present?
        raise ArgumentError, "idempotency_key requires turn_id" if effective_turn_id.blank?

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
            @graph.nodes.active.find_by!(
              turn_id: effective_turn_id,
              node_type: node_type,
              idempotency_key: idempotency_key
            )
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
      raise ArgumentError, "edge already exists but is archived" if existing

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

    def fork_from!(from_node:, node_type:, state:, body_input: {}, body_output: {}, metadata: {})
      assert_node_belongs_to_graph!(from_node)
      raise ArgumentError, "cannot fork from compressed nodes" if from_node.compressed_at.present?
      raise ArgumentError, "can only fork from terminal nodes" unless from_node.terminal?

      node = create_node(
        node_type: node_type,
        state: state,
        metadata: metadata,
        turn_id: nil,
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

      node
    end

    def retry_replace!(node:)
      old = locked_active_node!(node)
      now = Time.current

      unless old.body.retriable?
        raise ArgumentError, "can only retry retriable nodes (task, agent_message, character_message)"
      end

      unless [DAG::Node::ERRORED, DAG::Node::REJECTED, DAG::Node::CANCELLED].include?(old.state)
        raise ArgumentError, "can only retry errored, rejected, or cancelled nodes"
      end

      descendant_ids = active_causal_descendant_ids_for(old.id) - [old.id]
      if @graph.nodes.where(id: descendant_ids, compressed_at: nil).where.not(state: DAG::Node::PENDING).exists?
        raise ArgumentError, "cannot retry when downstream nodes are not pending"
      end

      outgoing_blocking_edges = active_outgoing_blocking_edges_from(old.id)
      if outgoing_blocking_edges.any?
        child_states = @graph.nodes.where(id: outgoing_blocking_edges.map(&:to_node_id)).pluck(:id, :state).to_h
        unless outgoing_blocking_edges.all? { |edge| child_states[edge.to_node_id] == DAG::Node::PENDING }
          raise ArgumentError, "can only retry when all active blocking children are pending"
        end
      end

      attempt = old.metadata.fetch("attempt", 1).to_i + 1
      body_input = old.body.input_for_retry
      retry_metadata =
        old.metadata
          .except("error", "reason", "blocked_by", "usage", "output_stats", "timing", "worker")
          .merge("attempt" => attempt)

      new_node = create_node(
        node_type: old.node_type,
        state: DAG::Node::PENDING,
        metadata: retry_metadata,
        retry_of_id: old.id,
        turn_id: old.turn_id,
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

    def regenerate_replace!(node:)
      old = locked_active_node!(node)
      now = Time.current

      unless old.body.regeneratable?
        raise ArgumentError, "can only regenerate regeneratable nodes"
      end

      unless old.state == DAG::Node::FINISHED
        raise ArgumentError, "can only regenerate finished nodes"
      end

      outgoing_blocking_edges = active_outgoing_blocking_edges_from(old.id)
      if outgoing_blocking_edges.any?
        raise ArgumentError, "can only regenerate leaf agent_message/character_message nodes"
      end

      new_node = create_node(
        node_type: old.node_type,
        state: DAG::Node::PENDING,
        metadata: old.metadata.except("error", "reason", "blocked_by", "usage", "output_stats", "timing", "worker"),
        turn_id: old.turn_id,
        body_input: old.body.input_for_retry,
      )

      copy_incoming_blocking_edges!(from_node_id: old.id, to_node_id: new_node.id)

      create_edge_by_id(
        from_node_id: old.id,
        to_node_id: new_node.id,
        edge_type: DAG::Edge::BRANCH,
        metadata: { "branch_kinds" => ["regenerate"] }
      )

      archived_edge_ids = archive_nodes_and_incident_edges!(node_ids: [old.id], compressed_by_id: new_node.id, now: now)

      @graph.emit_event(
        event_type: DAG::GraphHooks::EventTypes::NODE_REPLACED,
        subject: new_node,
        particulars: {
          "kind" => "regenerate",
          "old_id" => old.id,
          "new_id" => new_node.id,
          "archived_node_ids" => [old.id],
          "archived_edge_ids" => archived_edge_ids,
        }
      )

      new_node
    end

    def edit_replace!(node:, new_input:)
      old = locked_active_node!(node)
      now = Time.current

      unless old.body.editable?
        raise ArgumentError, "can only edit editable nodes"
      end

      unless old.state == DAG::Node::FINISHED
        raise ArgumentError, "can only edit finished nodes"
      end

      descendant_ids = active_causal_descendant_ids_for(old.id) - [old.id]
      if @graph.nodes.where(id: descendant_ids, compressed_at: nil, state: [DAG::Node::PENDING, DAG::Node::RUNNING]).exists?
        raise ArgumentError, "cannot edit when downstream nodes are pending or running"
      end

      new_body_input = old.body.input_for_retry.deep_merge(normalize_hash(new_input))

      new_node = create_node(
        node_type: old.node_type,
        state: DAG::Node::FINISHED,
        metadata: old.metadata.except("error", "reason", "blocked_by", "usage", "output_stats", "timing", "worker"),
        turn_id: old.turn_id,
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

        raise ArgumentError, "node must belong to the same graph"
      end

      def locked_active_node!(node_or_id)
        node_id = node_or_id.is_a?(DAG::Node) ? node_or_id.id : node_or_id
        @graph.nodes.where(compressed_at: nil).lock.find(node_id)
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
        raise ArgumentError, "edge already exists but is archived" if existing

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

        edge_ids = @graph.edges.active
          .where("from_node_id IN (?) OR to_node_id IN (?)", node_ids, node_ids)
          .pluck(:id)

        @graph.nodes.where(id: node_ids).update_all(
          compressed_at: now,
          compressed_by_id: compressed_by_id,
          updated_at: now
        )

        @graph.edges.where(id: edge_ids).update_all(compressed_at: now, updated_at: now)

        edge_ids
      end

      def normalize_hash(hash)
        if hash.is_a?(Hash)
          hash.deep_stringify_keys
        else
          {}
        end
      end

      def assert_idempotent_node_match!(node, expected_state:, expected_body_input:, expected_body_output:)
        if node.state != expected_state.to_s
          raise ArgumentError, "idempotency_key collision with mismatched state"
        end

        actual_body_input = node.body&.input.is_a?(Hash) ? node.body.input : {}
        actual_body_output = node.body&.output.is_a?(Hash) ? node.body.output : {}

        if actual_body_input != expected_body_input || actual_body_output != expected_body_output
          raise ArgumentError, "idempotency_key collision with mismatched body I/O"
        end
      end
  end
end
