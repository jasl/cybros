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

    def awaiting_approval_page(limit: 50, after_node_id: nil)
      graph.awaiting_approval_page(limit: limit, after_node_id: after_node_id, lane_id: id)
    end

    def awaiting_approval_scope
      graph.awaiting_approval_scope(lane_id: id)
    end

    def node_event_page_for(node_id, after_event_id: nil, limit: 200, kinds: nil)
      assert_target_node_belongs_to_lane!(node_id, include_compressed: true)
      graph.node_event_page_for(node_id, after_event_id: after_event_id, limit: limit, kinds: kinds)
    end

    def node_event_scope_for(node_id, kinds: nil)
      assert_target_node_belongs_to_lane!(node_id, include_compressed: true)
      graph.node_event_scope_for(node_id, kinds: kinds)
    end

    def context_for(
      target_node_id,
      limit_turns: DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
      mode: :preview,
      include_excluded: false,
      include_deleted: false
    )
      assert_target_node_belongs_to_lane!(target_node_id)

      DAG::ContextWindowAssembly.new(graph: graph).call(
        target_node_id,
        limit_turns: limit_turns,
        mode: mode,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def context_for_full(
      target_node_id,
      limit_turns: DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
      include_excluded: false,
      include_deleted: false
    )
      context_for(
        target_node_id,
        limit_turns: limit_turns,
        mode: :full,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def context_node_scope_for(
      target_node_id,
      limit_turns: DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS,
      include_excluded: false,
      include_deleted: false
    )
      assert_target_node_belongs_to_lane!(target_node_id)

      DAG::ContextWindowAssembly.new(graph: graph).node_scope_for(
        target_node_id,
        limit_turns: limit_turns,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def anchored_turn_page(limit:, before_seq: nil, after_seq: nil, include_deleted: true)
      limit = coerce_integer_param(limit, field: "limit", code: "dag.lane.limit_must_be_an_integer")
      return { "turns" => [], "before_seq" => nil, "after_seq" => nil } if limit <= 0

      limit = [limit, 1000].min

      before_seq =
        coerce_optional_integer_param(
          before_seq,
          field: "before_seq",
          code: "dag.lane.before_seq_must_be_an_integer",
        )
      after_seq =
        coerce_optional_integer_param(
          after_seq,
          field: "after_seq",
          code: "dag.lane.after_seq_must_be_an_integer",
        )

      if before_seq.present? && after_seq.present?
        PaginationError.raise!(
          "before_seq and after_seq are mutually exclusive",
          code: "dag.lane.before_seq_and_after_seq_are_mutually_exclusive",
          details: { before_seq: before_seq, after_seq: after_seq },
        )
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

    def message_page(limit:, before_message_id: nil, after_message_id: nil, mode: :preview, include_deleted: false)
      limit = coerce_integer_param(limit, field: "limit", code: "dag.lane.limit_must_be_an_integer")
      return empty_message_page if limit <= 0

      limit = [limit, 1000].min

      before_message_id = before_message_id&.to_s
      after_message_id = after_message_id&.to_s

      if before_message_id.present? && after_message_id.present?
        PaginationError.raise!(
          "before_message_id and after_message_id are mutually exclusive",
          code: "dag.lane.before_message_id_and_after_message_id_are_mutually_exclusive",
          details: { before_message_id: before_message_id, after_message_id: after_message_id },
        )
      end

      candidate_types = graph.transcript_candidate_node_types
      return empty_message_page if candidate_types.empty?

      scope = nodes.active.where(node_type: candidate_types)
      scope = scope.where(deleted_at: nil) unless include_deleted

      cursor_message_id = before_message_id || after_message_id
      if cursor_message_id.present?
        unless scope.where(id: cursor_message_id).exists?
          PaginationError.raise!(
            "cursor message_id is unknown or not visible",
            code: "dag.lane.cursor_message_id_is_unknown_or_not_visible",
            details: { cursor_message_id: cursor_message_id },
          )
        end
      end

      projection = DAG::TranscriptProjection.new(graph: graph)

      messages = []
      scanned = 0

        order = after_message_id.present? ? :asc : :desc
        batch_size = [limit * 3, 200].min
        max_scanned_nodes = DAG::SafetyLimits.max_message_page_scanned_nodes

        while messages.length < limit && scanned < max_scanned_nodes
        page =
          if cursor_message_id.present?
            if order == :asc
              scope.where("dag_nodes.id > ?", cursor_message_id)
            else
              scope.where("dag_nodes.id < ?", cursor_message_id)
            end
          else
            scope
          end

        node_records =
          page
            .order(id: order)
            .limit(batch_size)
            .select(:id, :turn_id, :lane_id, :node_type, :state, :metadata, :body_id)
            .to_a

        break if node_records.empty?

        scanned += node_records.length
        cursor_message_id = node_records.last.id

        batch_messages = projection.project(node_records: node_records, mode: mode)
        if batch_messages.any?
          messages.concat(batch_messages)
          messages = messages.first(limit) if messages.length > limit
        end
        end

      messages.reverse! if order == :desc

      message_ids = messages.map { |message| message.fetch("node_id") }

      {
        "message_ids" => message_ids,
        "before_message_id" => message_ids.first,
        "after_message_id" => message_ids.last,
        "messages" => messages,
      }
    end

    def llm_usage_stats(since: nil, until_time: nil, include_compressed: false, include_deleted: false)
      DAG::UsageStats.call(
        graph: graph,
        lane_id: id,
        since: since,
        until_time: until_time,
        include_compressed: include_compressed,
        include_deleted: include_deleted,
      )
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
      start_seq = coerce_integer_param(start_seq, field: "start_seq", code: "dag.lane.start_seq_must_be_an_integer")
      end_seq = coerce_integer_param(end_seq, field: "end_seq", code: "dag.lane.end_seq_must_be_an_integer")

      if start_seq > end_seq
        ValidationError.raise!(
          "start_seq must be <= end_seq",
          code: "dag.lane.start_seq_must_be_end_seq",
          details: { start_seq: start_seq, end_seq: end_seq },
        )
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
          OperationNotAllowedError.raise!(
            "cannot compact while graph has running nodes",
            code: "dag.lane.cannot_compact_while_graph_has_running_nodes",
          )
      end

        turn_nodes = nodes.active.where(turn_id: turn_id).lock.to_a

        unless turn_nodes.all?(&:terminal?)
          OperationNotAllowedError.raise!(
            "can only compact turns when all active nodes are terminal",
            code: "dag.lane.can_only_compact_turns_when_all_active_nodes_are_terminal",
          )
        end

        turn_node_ids = turn_nodes.map { |node| node.id.to_s }
        unexpected_keep_ids = keep_node_ids - turn_node_ids
        if unexpected_keep_ids.any?
          ValidationError.raise!(
            "keep_node_ids must belong to this lane and turn",
            code: "dag.lane.keep_node_ids_must_belong_to_this_lane_and_turn",
            details: { unexpected_keep_node_ids: unexpected_keep_ids.sort },
          )
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

      def empty_message_page
        {
          "message_ids" => [],
          "before_message_id" => nil,
          "after_message_id" => nil,
          "messages" => [],
        }
      end

      def coerce_integer_param(value, field:, code:)
        i = strict_integer(value)
        return i unless i.nil?

        PaginationError.raise!(
          "#{field} must be an Integer",
          code: code,
          details: { field: field.to_s, value_class: value.class.name, value_preview: value_preview(value) },
        )
      end

      def strict_integer(value)
        case value
        when Integer
          value
        when String
          s = value.strip
          return nil if s.empty?
          return nil unless s.match?(/\A[+-]?\d+\z/)

          Integer(s, 10)
        else
          nil
        end
      end

      def coerce_optional_integer_param(value, field:, code:)
        return nil unless value.present?

        coerce_integer_param(value, field: field, code: code)
      end

      def value_preview(value, max_bytes: 200)
        s = value.to_s
        s.bytesize > max_bytes ? s.byteslice(0, max_bytes).to_s : s
      end

      def assert_target_node_belongs_to_lane!(node_id, include_compressed: false)
        node_id = node_id.to_s

        scope = include_compressed ? graph.nodes : graph.nodes.active
        target_lane_id = scope.where(id: node_id).pick(:lane_id)
        return if target_lane_id.nil?
        return if target_lane_id.to_s == id.to_s

        ValidationError.raise!(
          "node_id must belong to this lane",
          code: "dag.lane.node_id_must_belong_to_this_lane",
          details: { node_id: node_id.to_s, lane_id: id.to_s, actual_lane_id: target_lane_id.to_s },
        )
      end

      def transcript_turn_ids_page(limit_turns:, before_turn_id:, after_turn_id:, include_deleted:)
        limit_turns = coerce_integer_param(limit_turns, field: "limit_turns", code: "dag.lane.limit_turns_must_be_an_integer")
        return [] if limit_turns <= 0

        limit_turns = [limit_turns, 1000].min

        before_turn_id = before_turn_id&.to_s
        after_turn_id = after_turn_id&.to_s

      if before_turn_id.present? && after_turn_id.present?
        PaginationError.raise!(
          "before_turn_id and after_turn_id are mutually exclusive",
          code: "dag.lane.before_turn_id_and_after_turn_id_are_mutually_exclusive",
          details: { before_turn_id: before_turn_id, after_turn_id: after_turn_id },
        )
      end

        visibility_column = include_deleted ? :anchor_node_id_including_deleted : :anchor_node_id

        visible_turns =
          graph.turns
            .where(lane_id: id)
            .where.not(visibility_column => nil)

        if before_turn_id.present?
          unless visible_turns.where(id: before_turn_id).exists?
            PaginationError.raise!(
              "cursor turn_id is unknown or not visible",
              code: "dag.lane.cursor_turn_id_is_unknown_or_not_visible",
              details: { cursor_turn_id: before_turn_id },
            )
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
            PaginationError.raise!(
              "cursor turn_id is unknown or not visible",
              code: "dag.lane.cursor_turn_id_is_unknown_or_not_visible",
              details: { cursor_turn_id: after_turn_id },
            )
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
