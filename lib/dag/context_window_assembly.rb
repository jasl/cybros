module DAG
  class ContextWindowAssembly
    DEFAULT_CONTEXT_TURNS = 50
    SUMMARY_PIN_LIMIT = 3

    PINNED_NODE_TYPES = %w[system_message developer_message].freeze

    def initialize(graph:)
      @graph = graph
    end

    def call(target_node_id, limit_turns: DEFAULT_CONTEXT_TURNS, mode: :preview, include_excluded: false, include_deleted: false)
      limit_turns = Integer(limit_turns)
      raise ArgumentError, "limit_turns must be > 0" if limit_turns <= 0

      target = load_target_node(target_node_id)
      return [] if target.nil?

      segments = segments_for_target(target)

      turn_ids =
        selected_turn_ids(
          target: target,
          segments: segments,
          limit_turns: limit_turns,
          include_deleted: include_deleted
        )

      pinned_node_ids = pinned_node_ids_for_context
      nodes = load_nodes(turn_ids: turn_ids, pinned_node_ids: pinned_node_ids)
      return [] if nodes.empty?

      edges = load_edges(node_ids: nodes.keys)
      ordered_ids = DAG::TopologicalSort.call(node_ids: nodes.keys, edges: edges)

      included_ids =
        ordered_ids.select do |node_id|
          include_node_in_context?(
            nodes.fetch(node_id),
            target_node_id: target.id,
            include_excluded: include_excluded,
            include_deleted: include_deleted
          )
        end

      included_nodes = included_ids.map { |node_id| nodes.fetch(node_id) }
      bodies = load_bodies(nodes: included_nodes, mode: mode)

      included_ids.map do |node_id|
        node = nodes.fetch(node_id)
        body = bodies[node.body_id]
        context_hash_for(node, body, mode: mode)
      end
    end

    def node_scope_for(target_node_id, limit_turns: DEFAULT_CONTEXT_TURNS, include_excluded: false, include_deleted: false)
      limit_turns = Integer(limit_turns)
      raise ArgumentError, "limit_turns must be > 0" if limit_turns <= 0

      target = load_target_node(target_node_id)
      return @graph.nodes.none if target.nil?

      segments = segments_for_target(target)

      turn_ids =
        selected_turn_ids(
          target: target,
          segments: segments,
          limit_turns: limit_turns,
          include_deleted: include_deleted
        )

      pinned_node_ids = pinned_node_ids_for_context

      scope = @graph.nodes.active.where(turn_id: turn_ids)
      scope = scope.or(@graph.nodes.active.where(id: pinned_node_ids)) if pinned_node_ids.any?

      scope = scope.where(context_excluded_at: nil) unless include_excluded
      scope = scope.where(deleted_at: nil) unless include_deleted

      scope.or(@graph.nodes.active.where(id: target.id))
    end

    private

      Segment = Data.define(:lane_id, :cutoff_node_id, :cutoff_created_at, :cutoff_turn_id)

      def load_target_node(target_node_id)
        @graph.nodes.active
          .where(id: target_node_id)
          .select(:id, :lane_id, :turn_id, :created_at)
          .first
      end

      def segments_for_target(target)
        segments = []

        segments.concat(lane_chain_segments(cutoff_node: target))

        blocking_sources = incoming_blocking_source_nodes(target_id: target.id)
        blocking_sources.each do |source|
          segments.concat(lane_chain_segments(cutoff_node: source))
        end

        segments.uniq { |segment| [segment.lane_id.to_s, segment.cutoff_node_id.to_s] }
      end

      def incoming_blocking_source_nodes(target_id:)
        from_ids =
          @graph.edges.active
            .where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES, to_node_id: target_id)
            .where(from_node_id: @graph.nodes.active.select(:id))
            .pluck(:from_node_id)

        return [] if from_ids.empty?

        @graph.nodes.active
          .where(id: from_ids)
          .select(:id, :lane_id, :turn_id, :created_at)
          .to_a
      end

      def lane_chain_segments(cutoff_node:)
        lane_id = cutoff_node.lane_id
        lane =
          @graph.lanes
            .where(id: lane_id)
            .select(:id, :parent_lane_id, :forked_from_node_id)
            .first
        return [] if lane.nil?

        segments = []
        visited = {}

        current_lane = lane
        current_cutoff_node = cutoff_node

        loop do
          break if current_lane.nil?
          break if visited[current_lane.id]

          visited[current_lane.id] = true

          segments << Segment.new(
            lane_id: current_lane.id,
            cutoff_node_id: current_cutoff_node.id,
            cutoff_created_at: current_cutoff_node.created_at,
            cutoff_turn_id: current_cutoff_node.turn_id
          )

          parent_lane_id = current_lane.parent_lane_id
          break if parent_lane_id.blank?

          fork_node_id = current_lane.forked_from_node_id
          break if fork_node_id.blank?

          parent_lane =
            @graph.lanes
              .where(id: parent_lane_id)
              .select(:id, :parent_lane_id, :forked_from_node_id)
              .first
          break if parent_lane.nil?

          fork_node =
            @graph.nodes
              .where(id: fork_node_id)
              .select(:id, :lane_id, :turn_id, :created_at)
              .first
          break if fork_node.nil?
          break if fork_node.lane_id.to_s != parent_lane.id.to_s

          current_lane = parent_lane
          current_cutoff_node = fork_node
        end

        segments
      end

      def selected_turn_ids(target:, segments:, limit_turns:, include_deleted:)
        window_turn_ids =
          window_turn_ids_for_segments(
            segments,
            limit_turns: limit_turns,
            include_deleted: include_deleted
          )

        pinned_turn_ids = segments.map { |segment| segment.cutoff_turn_id.to_s }

        (window_turn_ids + pinned_turn_ids + [target.turn_id.to_s]).uniq
      end

      def window_turn_ids_for_segments(segments, limit_turns:, include_deleted:)
        turn_rows =
          segments.flat_map do |segment|
            anchored_turn_rows_for_segment(
              segment,
              limit_turns: limit_turns,
              include_deleted: include_deleted
            )
          end

        return [] if turn_rows.empty?

        unique =
          turn_rows.uniq { |row| row.fetch(:turn_id).to_s }

        recent =
          unique
            .sort_by { |row| [row.fetch(:anchor_created_at), row.fetch(:anchor_node_id).to_s] }
            .last(limit_turns)

        recent.map { |row| row.fetch(:turn_id).to_s }
      end

      def anchored_turn_rows_for_segment(segment, limit_turns:, include_deleted:)
        cutoff_at = segment.cutoff_created_at
        cutoff_node_id = segment.cutoff_node_id

        scope =
          @graph.turns
            .where(lane_id: segment.lane_id)
            .where.not(anchor_node_id: nil)
            .joins(<<~SQL.squish)
              JOIN dag_nodes anchors
                ON anchors.id = dag_turns.anchor_node_id
               AND anchors.graph_id = dag_turns.graph_id
               AND anchors.lane_id = dag_turns.lane_id
            SQL
            .where(Arel.sql("anchors.compressed_at IS NULL"))

        scope = scope.where(Arel.sql("anchors.deleted_at IS NULL")) unless include_deleted

        scope =
          scope.where(
            "dag_turns.anchor_created_at < ? OR (dag_turns.anchor_created_at = ? AND dag_turns.anchor_node_id <= ?)",
            cutoff_at,
            cutoff_at,
            cutoff_node_id
          )

        scope
          .order(Arel.sql("dag_turns.anchor_created_at DESC"), Arel.sql("dag_turns.anchor_node_id DESC"))
          .limit(limit_turns)
          .pluck(
            Arel.sql("dag_turns.id"),
            Arel.sql("dag_turns.anchor_created_at"),
            Arel.sql("dag_turns.anchor_node_id")
          )
          .map do |turn_id, anchor_created_at, anchor_node_id|
            { turn_id: turn_id, anchor_created_at: anchor_created_at, anchor_node_id: anchor_node_id }
          end
      end

      def pinned_node_ids_for_context
        pinned = @graph.nodes.active.where(node_type: PINNED_NODE_TYPES).pluck(:id)

        summary_ids =
          @graph.nodes.active
            .where(node_type: "summary")
            .order(created_at: :desc, id: :desc)
            .limit(SUMMARY_PIN_LIMIT)
            .pluck(:id)

        (pinned + summary_ids).uniq
      end

      def load_nodes(turn_ids:, pinned_node_ids:)
        node_records = []

        node_records.concat(
          @graph.nodes.active
            .where(turn_id: turn_ids)
            .select(:id, :turn_id, :lane_id, :node_type, :state, :metadata, :body_id, :context_excluded_at, :deleted_at)
            .to_a
        )

        if pinned_node_ids.any?
          node_records.concat(
            @graph.nodes.active
              .where(id: pinned_node_ids)
              .select(:id, :turn_id, :lane_id, :node_type, :state, :metadata, :body_id, :context_excluded_at, :deleted_at)
              .to_a
          )
        end

        node_records.uniq { |node| node.id }.index_by(&:id)
      end

      def load_edges(node_ids:)
        @graph.edges.active
          .where(
            edge_type: DAG::Edge::BLOCKING_EDGE_TYPES,
            from_node_id: node_ids,
            to_node_id: node_ids
          )
          .pluck(:from_node_id, :to_node_id)
          .map { |from_node_id, to_node_id| { from: from_node_id, to: to_node_id } }
      end

      def load_bodies(nodes:, mode:)
        body_ids = nodes.map(&:body_id).compact.uniq

        body_scope = DAG::NodeBody.where(id: body_ids)
        body_scope =
          if mode.to_sym == :full
            body_scope.select(:id, :type, :input, :output, :output_preview)
          else
            body_scope.select(:id, :type, :input, :output_preview)
          end

        body_scope.index_by(&:id)
      end

      def include_node_in_context?(node, target_node_id:, include_excluded:, include_deleted:)
        return true if node.id.to_s == target_node_id.to_s

        return false if !include_deleted && node.deleted_at.present?
        return false if !include_excluded && node.context_excluded_at.present?

        true
      end

      def context_hash_for(node, body, mode:)
        payload_hash = {
          "input" => body&.input.is_a?(Hash) ? body.input : {},
          "output_preview" => body&.output_preview.is_a?(Hash) ? body.output_preview : {},
        }

        if mode.to_sym == :full
          payload_hash["output"] = body&.output.is_a?(Hash) ? body.output : {}
        end

        {
          "node_id" => node.id,
          "turn_id" => node.turn_id,
          "lane_id" => node.lane_id,
          "node_type" => node.node_type,
          "state" => node.state,
          "payload" => payload_hash,
          "metadata" => node.metadata,
        }
      end
  end
end
