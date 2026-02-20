module DAG
  class Subgraph < ApplicationRecord
    self.table_name = "dag_subgraphs"

    MAIN = "main"
    BRANCH = "branch"

    ROLES = [MAIN, BRANCH].freeze

    enum :role, ROLES.index_by(&:itself)

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :subgraphs

    belongs_to :parent_subgraph, class_name: "DAG::Subgraph", optional: true
    has_many :child_subgraphs,
             class_name: "DAG::Subgraph",
             foreign_key: :parent_subgraph_id,
             dependent: :nullify,
             inverse_of: :parent_subgraph

    belongs_to :forked_from_node, class_name: "DAG::Node", optional: true
    belongs_to :root_node, class_name: "DAG::Node", optional: true
    belongs_to :merged_into_subgraph, class_name: "DAG::Subgraph", optional: true

    belongs_to :attachable, polymorphic: true, optional: true

    has_many :nodes,
             class_name: "DAG::Node",
             inverse_of: :subgraph
    has_many :turns,
             class_name: "DAG::Turn",
             inverse_of: :subgraph

    validates :role, inclusion: { in: ROLES }
    validate :subgraph_relationships_must_match_graph

    def archived?
      archived_at.present?
    end

    def anchored_turn_page(limit:, before_seq: nil, after_seq: nil, include_deleted: true)
      limit = Integer(limit)
      return { "turns" => [], "before_seq" => nil, "after_seq" => nil } if limit <= 0

      before_seq = before_seq&.to_i
      after_seq = after_seq&.to_i

      if before_seq.present? && after_seq.present?
        raise ArgumentError, "before_seq and after_seq are mutually exclusive"
      end

      scope = turns.where.not(anchored_seq: nil)
      scope = scope.where.not(anchor_node_id: nil) unless include_deleted

      if before_seq.present?
        scope = scope.where("anchored_seq < ?", before_seq).order(anchored_seq: :desc)
        rows = scope.limit(limit).pluck(:id, :anchored_seq).reverse
      elsif after_seq.present?
        scope = scope.where("anchored_seq > ?", after_seq).order(anchored_seq: :asc)
        rows = scope.limit(limit).pluck(:id, :anchored_seq)
      else
        scope = scope.order(anchored_seq: :desc)
        rows = scope.limit(limit).pluck(:id, :anchored_seq).reverse
      end

      turns_payload =
        rows.map do |turn_id, anchored_seq|
          {
            "turn_id" => turn_id.to_s,
            "anchored_seq" => anchored_seq.to_i,
          }
        end

      {
        "turns" => turns_payload,
        "before_seq" => turns_payload.first&.fetch("anchored_seq", nil),
        "after_seq" => turns_payload.last&.fetch("anchored_seq", nil),
      }
    end

    def anchored_turn_count(include_deleted: true)
      if include_deleted
        self.class.where(graph_id: graph_id, id: id).pick(:next_anchored_seq).to_i
      else
        turns.where.not(anchored_seq: nil).where.not(anchor_node_id: nil).count
      end
    end

    def anchored_turn_seq_for(turn_id, include_deleted: true)
      turn_id = turn_id.to_s
      row =
        turns
          .where(id: turn_id)
          .select(:anchored_seq, :anchor_node_id)
          .first

      return nil if row.nil?
      return nil if row.anchored_seq.nil?
      return nil if !include_deleted && row.anchor_node_id.nil?

      row.anchored_seq.to_i
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
      transcript_page(limit_turns: limit_turns, mode: mode, include_deleted: include_deleted).fetch("transcript")
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
        "turn_ids" => turn_ids,
        "before_turn_id" => turn_ids.first,
        "after_turn_id" => turn_ids.last,
        "transcript" => transcript,
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
        turns
          .where.not(anchored_seq: nil)
          .where(anchored_seq: start_seq..end_seq)
          .order(:anchored_seq)
          .pluck(:id)

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
          raise ArgumentError, "keep_node_ids must belong to this subgraph and turn"
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

        visibility_column = include_deleted ? :anchor_node_id_including_deleted : :anchor_node_id

        visible_turns =
          graph.turns
            .where(subgraph_id: id)
            .where.not(visibility_column => nil)

        if before_turn_id.present?
          unless visible_turns.where(id: before_turn_id).exists?
            raise ArgumentError, "cursor turn_id is unknown or not visible"
          end

          visible_turns
            .where("dag_turns.id < ?", before_turn_id)
            .order(id: :desc)
            .limit(limit_turns)
            .pluck(:id)
            .reverse
            .map(&:to_s)
        elsif after_turn_id.present?
          unless visible_turns.where(id: after_turn_id).exists?
            raise ArgumentError, "cursor turn_id is unknown or not visible"
          end

          visible_turns
            .where("dag_turns.id > ?", after_turn_id)
            .order(id: :asc)
            .limit(limit_turns)
            .pluck(:id)
            .map(&:to_s)
        else
          visible_turns
            .order(id: :desc)
            .limit(limit_turns)
            .pluck(:id)
            .reverse
            .map(&:to_s)
        end
      end

      def transcript_for_turn_ids(turn_ids:, mode:, include_deleted:)
        turn_ids = Array(turn_ids).map(&:to_s).uniq
        return [] if turn_ids.empty?

        candidate_types = graph.transcript_candidate_node_types
        return [] if candidate_types.empty?

        node_scope = graph.nodes.active.where(subgraph_id: id, turn_id: turn_ids, node_type: candidate_types)
        node_scope = node_scope.where(deleted_at: nil) unless include_deleted

        node_records =
          node_scope
            .select(:id, :turn_id, :subgraph_id, :node_type, :state, :metadata, :body_id)
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

            emit_context_visibility_event!(
              node,
              from_context_excluded_at: node.context_excluded_at,
              to_context_excluded_at: nil,
              action: "include_in_context"
            )
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

            emit_context_visibility_event!(
              node,
              from_context_excluded_at: node.context_excluded_at,
              to_context_excluded_at: at,
              action: "exclude_from_context"
            )
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

      def subgraph_relationships_must_match_graph
        return if graph_id.blank?

        if parent_subgraph && parent_subgraph.graph_id != graph_id
          errors.add(:parent_subgraph_id, "must belong to the same graph")
        end

        if merged_into_subgraph && merged_into_subgraph.graph_id != graph_id
          errors.add(:merged_into_subgraph_id, "must belong to the same graph")
        end

        if forked_from_node && forked_from_node.graph_id != graph_id
          errors.add(:forked_from_node_id, "must belong to the same graph")
        end

        if root_node
          if root_node.graph_id != graph_id
            errors.add(:root_node_id, "must belong to the same graph")
          end

          if root_node.subgraph_id != id
            errors.add(:root_node_id, "must belong to this subgraph")
          end
        end
      end
  end
end
