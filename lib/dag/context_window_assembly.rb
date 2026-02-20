  module DAG
    class ContextWindowAssembly
      DEFAULT_CONTEXT_TURNS = 50
      SUMMARY_PIN_LIMIT = 3

    PINNED_NODE_TYPES = %w[system_message developer_message].freeze

    def initialize(graph:)
      @graph = graph
      @lane_cache = {}
      @node_cache = {}
    end

      def call(target_node_id, limit_turns: DEFAULT_CONTEXT_TURNS, mode: :preview, include_excluded: false, include_deleted: false)
      limit_turns = Integer(limit_turns)
      raise ArgumentError, "limit_turns must be > 0" if limit_turns <= 0
      limit_turns = [limit_turns, 1000].min

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
      limit_turns = [limit_turns, 1000].min

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

      Segment = Data.define(:lane_id, :cutoff_turn_id)

      def load_target_node(target_node_id)
        @graph.nodes.active
          .where(id: target_node_id)
          .select(:id, :lane_id, :turn_id)
          .first
      end

      def segments_for_target(target)
        segments = []

        segments.concat(lane_chain_segments(cutoff_node: target))

        blocking_sources = incoming_blocking_source_nodes(target_id: target.id)
        blocking_sources.each do |source|
          segments.concat(lane_chain_segments(cutoff_node: source))
        end

        segments.uniq { |segment| [segment.lane_id.to_s, segment.cutoff_turn_id.to_s] }
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
          .select(:id, :lane_id, :turn_id)
          .to_a
      end

      def lane_chain_segments(cutoff_node:)
        lane_id = cutoff_node.lane_id
        lane = lane_record(lane_id)
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
            cutoff_turn_id: current_cutoff_node.turn_id
          )

          parent_lane_id = current_lane.parent_lane_id
          break if parent_lane_id.blank?

          fork_node_id = current_lane.forked_from_node_id
          break if fork_node_id.blank?

          parent_lane = lane_record(parent_lane_id)
          break if parent_lane.nil?

          fork_node = node_record(fork_node_id)
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
        segments =
          segments
            .group_by(&:lane_id)
            .values
            .map do |lane_segments|
              lane_segments.max_by { |segment| segment.cutoff_turn_id.to_s }
            end

        turn_ids =
          segments.flat_map do |segment|
            anchored_turn_ids_for_segment(
              segment,
              limit_turns: limit_turns,
              include_deleted: include_deleted
            )
          end

        return [] if turn_ids.empty?

        turn_ids
          .uniq
          .sort
          .last(limit_turns)
      end

      def anchored_turn_ids_for_segment(segment, limit_turns:, include_deleted:)
        cutoff_turn_id = segment.cutoff_turn_id.to_s
        return [] if cutoff_turn_id.blank?

        visibility_column = include_deleted ? :anchor_node_id_including_deleted : :anchor_node_id

        @graph.turns
          .where(lane_id: segment.lane_id)
          .where.not(visibility_column => nil)
          .where("dag_turns.id <= ?", cutoff_turn_id)
          .order(id: :desc)
          .limit(limit_turns)
          .pluck(:id)
          .map(&:to_s)
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
          max_nodes = DAG::SafetyLimits.max_context_nodes
          node_records = []

          node_records.concat(
            @graph.nodes.active
              .where(turn_id: turn_ids)
              .limit(max_nodes + 1)
              .select(:id, :turn_id, :lane_id, :node_type, :state, :metadata, :body_id, :context_excluded_at, :deleted_at)
              .to_a
          )

          if node_records.length > max_nodes
            raise DAG::SafetyLimits::Exceeded, "context node limit exceeded (limit=#{max_nodes})"
          end

          if pinned_node_ids.any?
            node_records.concat(
              @graph.nodes.active
                .where(id: pinned_node_ids)
                .select(:id, :turn_id, :lane_id, :node_type, :state, :metadata, :body_id, :context_excluded_at, :deleted_at)
                .to_a
            )
          end

          nodes = node_records.uniq { |node| node.id }
          if nodes.length > max_nodes
            raise DAG::SafetyLimits::Exceeded, "context node limit exceeded (limit=#{max_nodes})"
          end

          nodes.index_by(&:id)
        end

        def load_edges(node_ids:)
          max_edges = DAG::SafetyLimits.max_context_edges
          @graph.edges.active
            .where(
              edge_type: DAG::Edge::BLOCKING_EDGE_TYPES,
              from_node_id: node_ids,
              to_node_id: node_ids
            )
            .limit(max_edges + 1)
            .pluck(:from_node_id, :to_node_id)
            .tap do |rows|
              if rows.length > max_edges
                raise DAG::SafetyLimits::Exceeded, "context edge limit exceeded (limit=#{max_edges})"
              end
            end
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

      def lane_record(lane_id)
        lane_id = lane_id.to_s
        @lane_cache[lane_id] ||=
          @graph.lanes
            .where(id: lane_id)
            .select(:id, :parent_lane_id, :forked_from_node_id)
            .first
      end

      def node_record(node_id)
        node_id = node_id.to_s
        @node_cache[node_id] ||=
          @graph.nodes
            .where(id: node_id)
            .select(:id, :lane_id, :turn_id)
            .first
      end
    end
  end
