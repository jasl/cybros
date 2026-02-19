module DAG
  class Lane < ApplicationRecord
    self.table_name = "dag_lanes"

    MAIN = "main"
    BRANCH = "branch"

    ROLES = [MAIN, BRANCH].freeze

    enum :role, ROLES.index_by(&:itself)

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :lanes
    belongs_to :parent_lane, class_name: "DAG::Lane", optional: true
    has_many :child_lanes,
             class_name: "DAG::Lane",
             foreign_key: :parent_lane_id,
             dependent: :nullify,
             inverse_of: :parent_lane

    belongs_to :forked_from_node, class_name: "DAG::Node", optional: true
    belongs_to :root_node, class_name: "DAG::Node", optional: true
    belongs_to :merged_into_lane, class_name: "DAG::Lane", optional: true

    belongs_to :attachable, polymorphic: true, optional: true

    has_many :nodes,
             class_name: "DAG::Node",
             inverse_of: :lane
    has_many :turns,
             class_name: "DAG::Turn",
             inverse_of: :lane

    validates :role, inclusion: { in: ROLES }
    validate :lane_relationships_must_match_graph

    def archived?
      archived_at.present?
    end

    def turns(include_deleted: true)
      turn_anchor_types = graph.turn_anchor_node_types

      if turn_anchor_types.empty?
        []
      else
        anchor_rows =
          graph.turns
            .where(lane_id: id)
            .where.not(anchor_node_id: nil)
            .joins("JOIN dag_nodes anchors ON anchors.id = dag_turns.anchor_node_id")
            .order(Arel.sql("dag_turns.anchor_created_at ASC"), Arel.sql("dag_turns.anchor_node_id ASC"))
            .pluck(
              Arel.sql("dag_turns.id"),
              Arel.sql("dag_turns.anchor_created_at"),
              Arel.sql("anchors.deleted_at IS NOT NULL")
            )

        turns =
          anchor_rows.each_with_index.map do |(turn_id, anchor_created_at, anchor_deleted), index|
            {
              turn_id: turn_id,
              seq: index + 1,
              anchor_created_at: anchor_created_at,
              anchor_deleted: anchor_deleted == true,
            }
          end

        if include_deleted
          turns
        else
          turns.reject { |turn| turn.fetch(:anchor_deleted) }
        end
      end
    end

    def visible_turns
      turns(include_deleted: false)
    end

    def turn_count(include_deleted: true)
      turns(include_deleted: include_deleted).length
    end

    def turn_ids(include_deleted: true)
      turns(include_deleted: include_deleted).map { |turn| turn.fetch(:turn_id) }
    end

    def turn_seq_for(turn_id, include_deleted: true)
      turn_id = turn_id.to_s

      turn = turns(include_deleted: include_deleted).find { |row| row.fetch(:turn_id).to_s == turn_id }

      if turn
        turn.fetch(:seq)
      end
    end

    def turn_anchor_node_ids(turn_id, include_compressed: false, include_deleted: true)
      turn_anchor_types = graph.turn_anchor_node_types

      if turn_anchor_types.empty?
        []
      else
        scope = include_compressed ? nodes : nodes.active
        scope = scope.where(turn_id: turn_id, node_type: turn_anchor_types)
        scope = scope.where(deleted_at: nil) unless include_deleted

        scope.order(:id).pluck(:id)
      end
    end

    def transcript_recent_turns(limit_turns:, mode: :preview, include_deleted: false)
      transcript_page(limit_turns: limit_turns, mode: mode, include_deleted: include_deleted).fetch(:transcript)
    end

    def transcript_page(limit_turns:, before_turn_id: nil, after_turn_id: nil, mode: :preview, include_deleted: false)
      turn_ids =
        transcript_turn_ids_page(
          limit_turns: limit_turns,
          before_turn_id: before_turn_id,
          after_turn_id: after_turn_id,
          include_deleted: include_deleted
        )

      transcript = transcript_for_turn_ids(turn_ids: turn_ids, mode: mode, include_deleted: include_deleted)

      {
        turn_ids: turn_ids,
        before_turn_id: turn_ids.first,
        after_turn_id: turn_ids.last,
        transcript: transcript,
      }
    end

    def turn_node_ids(turn_id, include_compressed: false, include_deleted: true)
      scope = include_compressed ? nodes : nodes.active
      scope = scope.where(turn_id: turn_id)
      scope = scope.where(deleted_at: nil) unless include_deleted

      scope.order(:id).pluck(:id)
    end

    def node_ids_for_turn_ids(turn_ids:, include_compressed: false, include_deleted: true)
      turn_ids = Array(turn_ids).map(&:to_s).uniq
      return [] if turn_ids.empty?

      scope = include_compressed ? nodes : nodes.active
      scope = scope.where(turn_id: turn_ids)
      scope = scope.where(deleted_at: nil) unless include_deleted

      scope.order(:id).pluck(:id)
    end

    def node_ids_for_turn_seq_range(start_seq:, end_seq:, include_compressed: false, include_deleted: true)
      start_seq = Integer(start_seq)
      end_seq = Integer(end_seq)

      if start_seq > end_seq
        raise ArgumentError, "start_seq must be <= end_seq"
      end

      turn_ids =
        turns(include_deleted: true)
          .select { |row| row.fetch(:seq).between?(start_seq, end_seq) }
          .map { |row| row.fetch(:turn_id) }

      node_ids_for_turn_ids(
        turn_ids: turn_ids,
        include_compressed: include_compressed,
        include_deleted: include_deleted
      )
    end

    def compress_turn_seq_range!(start_seq:, end_seq:, summary_content:, summary_metadata: {})
      node_ids =
        node_ids_for_turn_seq_range(
          start_seq: start_seq,
          end_seq: end_seq,
          include_compressed: false,
          include_deleted: true
        )

      graph.compress!(
        node_ids: node_ids,
        summary_content: summary_content,
        summary_metadata: summary_metadata
      )
    end

    def compact_turn_context!(turn_id:, keep_node_ids:, at: Time.current)
      keep_node_ids = Array(keep_node_ids).map(&:to_s).uniq
      now = Time.current

      graph.with_graph_lock! do
        if graph.nodes.active.where(state: DAG::Node::RUNNING).exists?
          raise ArgumentError, "cannot compact while graph has running nodes"
        end

        turn_nodes = nodes.active.where(turn_id: turn_id).lock.to_a

        unless turn_nodes.all?(&:terminal?)
          raise ArgumentError, "can only compact turns when all active nodes are terminal"
        end

        turn_node_ids = turn_nodes.map { |node| node.id.to_s }
        unexpected_keep_ids = keep_node_ids - turn_node_ids
        if unexpected_keep_ids.any?
          raise ArgumentError, "keep_node_ids must belong to this lane and turn"
        end

        keep_nodes = turn_nodes.select { |node| keep_node_ids.include?(node.id.to_s) }
        exclude_nodes = turn_nodes.reject { |node| keep_node_ids.include?(node.id.to_s) }

        apply_compact_context_visibility!(
          keep_nodes: keep_nodes,
          exclude_nodes: exclude_nodes,
          at: at,
          now: now
        )
      end
    end

    private

      def transcript_turn_ids_page(limit_turns:, before_turn_id:, after_turn_id:, include_deleted:)
        limit_turns = Integer(limit_turns)
        return [] if limit_turns <= 0

        before_turn_id = before_turn_id&.to_s
        after_turn_id = after_turn_id&.to_s

        if before_turn_id.present? && after_turn_id.present?
          raise ArgumentError, "before_turn_id and after_turn_id are mutually exclusive"
        end

        turn_anchor_types = graph.turn_anchor_node_types
        if turn_anchor_types.empty?
          []
        else
          anchors =
            graph.turns
              .where(lane_id: id)
              .where.not(anchor_node_id: nil)
              .joins("JOIN dag_nodes anchors ON anchors.id = dag_turns.anchor_node_id")
              .where(Arel.sql("anchors.compressed_at IS NULL"))

          anchors = anchors.where(Arel.sql("anchors.deleted_at IS NULL")) unless include_deleted

          cursor_created_at = nil
          cursor_anchor_id = nil

          if before_turn_id.present? || after_turn_id.present?
            cursor_turn_id = before_turn_id.presence || after_turn_id

            cursor_created_at, cursor_anchor_id =
              anchors
                .where("dag_turns.id = ?", cursor_turn_id)
                .pick(Arel.sql("dag_turns.anchor_created_at"), Arel.sql("dag_turns.anchor_node_id"))

            if cursor_created_at.nil? || cursor_anchor_id.nil?
              raise ArgumentError, "cursor turn_id is unknown or not visible"
            end
          end

          if before_turn_id.present?
            turn_ids =
              anchors
                .where(
                  "dag_turns.anchor_created_at < ? OR (dag_turns.anchor_created_at = ? AND dag_turns.anchor_node_id < ?)",
                  cursor_created_at,
                  cursor_created_at,
                  cursor_anchor_id
                )
                .order(Arel.sql("dag_turns.anchor_created_at DESC"), Arel.sql("dag_turns.anchor_node_id DESC"))
                .limit(limit_turns)
                .pluck(Arel.sql("dag_turns.id"))
                .reverse
          elsif after_turn_id.present?
            turn_ids =
              anchors
                .where(
                  "dag_turns.anchor_created_at > ? OR (dag_turns.anchor_created_at = ? AND dag_turns.anchor_node_id > ?)",
                  cursor_created_at,
                  cursor_created_at,
                  cursor_anchor_id
                )
                .order(Arel.sql("dag_turns.anchor_created_at ASC"), Arel.sql("dag_turns.anchor_node_id ASC"))
                .limit(limit_turns)
                .pluck(Arel.sql("dag_turns.id"))
          else
            turn_ids =
              anchors
                .order(Arel.sql("dag_turns.anchor_created_at DESC"), Arel.sql("dag_turns.anchor_node_id DESC"))
                .limit(limit_turns)
                .pluck(Arel.sql("dag_turns.id"))
                .reverse
          end

          turn_ids.map(&:to_s)
        end
      end

      def transcript_for_turn_ids(turn_ids:, mode:, include_deleted:)
        turn_ids = Array(turn_ids).map(&:to_s).uniq
        return [] if turn_ids.empty?

        candidate_types = graph.transcript_candidate_node_types
        return [] if candidate_types.empty?

        node_scope = graph.nodes.active.where(lane_id: id, turn_id: turn_ids, node_type: candidate_types)
        node_scope = node_scope.where(deleted_at: nil) unless include_deleted

        node_records =
          node_scope
            .select(:id, :turn_id, :lane_id, :node_type, :state, :metadata, :body_id)
            .order(:id)
            .to_a

        by_turn = node_records.group_by(&:turn_id)
        ordered_nodes = turn_ids.flat_map { |turn_id| by_turn.fetch(turn_id, []) }

        projection = DAG::TranscriptProjection.new(graph: graph)
        projection.project(node_records: ordered_nodes, mode: mode)
      end

      def apply_compact_context_visibility!(keep_nodes:, exclude_nodes:, at:, now:)
        keep_ids =
          keep_nodes
            .select { |node| node.context_excluded_at.present? }
            .map(&:id)

        if keep_ids.any?
          nodes.where(id: keep_ids).update_all(context_excluded_at: nil, updated_at: now)
          DAG::NodeVisibilityPatch.where(graph_id: graph_id, node_id: keep_ids).delete_all

          keep_nodes.each do |node|
            next unless keep_ids.include?(node.id)

            emit_context_visibility_event!(node, from_context_excluded_at: node.context_excluded_at, to_context_excluded_at: nil, action: "include_in_context")
          end
        end

        exclude_ids =
          exclude_nodes
            .reject { |node| node.context_excluded_at == at }
            .map(&:id)

        if exclude_ids.any?
          nodes.where(id: exclude_ids).update_all(context_excluded_at: at, updated_at: now)
          DAG::NodeVisibilityPatch.where(graph_id: graph_id, node_id: exclude_ids).delete_all

          exclude_nodes.each do |node|
            next unless exclude_ids.include?(node.id)

            emit_context_visibility_event!(node, from_context_excluded_at: node.context_excluded_at, to_context_excluded_at: at, action: "exclude_from_context")
          end
        end
      end

      def emit_context_visibility_event!(node, from_context_excluded_at:, to_context_excluded_at:, action:)
        from = visibility_snapshot_for(context_excluded_at: from_context_excluded_at, deleted_at: node.deleted_at)
        to = visibility_snapshot_for(context_excluded_at: to_context_excluded_at, deleted_at: node.deleted_at)
        return if from == to

        graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_CHANGED,
          subject: node,
          particulars: {
            "action" => action,
            "source" => "strict",
            "from" => from,
            "to" => to,
          }
        )
      end

      def visibility_snapshot_for(context_excluded_at:, deleted_at:)
        {
          "context_excluded_at" => context_excluded_at&.iso8601,
          "deleted_at" => deleted_at&.iso8601,
        }
      end

      def lane_relationships_must_match_graph
        return if graph_id.blank?

        if parent_lane && parent_lane.graph_id != graph_id
          errors.add(:parent_lane_id, "must belong to the same graph")
        end

        if merged_into_lane && merged_into_lane.graph_id != graph_id
          errors.add(:merged_into_lane_id, "must belong to the same graph")
        end

        if forked_from_node && forked_from_node.graph_id != graph_id
          errors.add(:forked_from_node_id, "must belong to the same graph")
        end

        if root_node
          if root_node.graph_id != graph_id
            errors.add(:root_node_id, "must belong to the same graph")
          end

          if root_node.lane_id != id
            errors.add(:root_node_id, "must belong to this lane")
          end
        end
      end
  end
end
