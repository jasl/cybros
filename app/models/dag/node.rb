module DAG
  class Node < ApplicationRecord
    self.table_name = "dag_nodes"

    PENDING = "pending"
    RUNNING = "running"
    FINISHED = "finished"
    ERRORED = "errored"
    REJECTED = "rejected"
    SKIPPED = "skipped"
    CANCELLED = "cancelled"

    STATES = [PENDING, RUNNING, FINISHED, ERRORED, REJECTED, SKIPPED, CANCELLED].freeze
    TERMINAL_STATES = [FINISHED, ERRORED, REJECTED, SKIPPED, CANCELLED].freeze

    enum :state, STATES.index_by(&:itself)

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :nodes
    belongs_to :lane, class_name: "DAG::Lane", inverse_of: :nodes
    belongs_to :turn,
               class_name: "DAG::Turn",
               foreign_key: :turn_id,
               optional: true,
               inverse_of: :nodes
    belongs_to :body,
               class_name: "DAG::NodeBody",
               autosave: true,
               dependent: :destroy,
               inverse_of: :node
    belongs_to :retry_of, class_name: "DAG::Node", optional: true
    belongs_to :compressed_by, class_name: "DAG::Node", optional: true

    has_many :outgoing_edges,
             class_name: "DAG::Edge",
             foreign_key: :from_node_id,
             dependent: :destroy,
             inverse_of: :from_node
    has_many :incoming_edges,
             class_name: "DAG::Edge",
             foreign_key: :to_node_id,
             dependent: :destroy,
             inverse_of: :to_node
    has_many :node_events,
             class_name: "DAG::NodeEvent",
             inverse_of: :node

    validates :node_type, presence: true
    validates :state, inclusion: { in: STATES }
    validate :body_type_matches_node_type
    validate :pending_or_running_requires_executable_body
    validate :turn_lane_must_be_consistent
    validate :lane_must_be_writable, on: :create

    scope :active, -> { where(compressed_at: nil) }

    before_validation :ensure_lane
    before_validation :ensure_body
    after_create :ensure_turn_record!

    def terminal?
      TERMINAL_STATES.include?(state)
    end

    def executable?
      body&.executable? == true
    end

    def context_excluded?
      context_excluded_at.present?
    end

    def deleted?
      deleted_at.present?
    end

    def usage
      metadata.is_a?(Hash) ? metadata["usage"] : nil
    end

    def output_stats
      metadata.is_a?(Hash) ? metadata["output_stats"] : nil
    end

    def exclude_from_context!(at: Time.current)
      graph.with_graph_lock! do
        assert_visibility_mutation_allowed!
        from = visibility_snapshot
        update_visibility_columns!(context_excluded_at: at)
        clear_visibility_patch!
        emit_visibility_changed_event!(from: from, to: visibility_snapshot, source: "strict", action: "exclude_from_context")
      end
    end

    def can_exclude_from_context?
      visibility_mutation_allowed_now? && !context_excluded?
    end

    def include_in_context!
      graph.with_graph_lock! do
        assert_visibility_mutation_allowed!
        from = visibility_snapshot
        update_visibility_columns!(context_excluded_at: nil)
        clear_visibility_patch!
        emit_visibility_changed_event!(from: from, to: visibility_snapshot, source: "strict", action: "include_in_context")
      end
    end

    def can_include_in_context?
      visibility_mutation_allowed_now? && context_excluded?
    end

    def soft_delete!(at: Time.current)
      graph.with_graph_lock! do
        assert_visibility_mutation_allowed!
        from = visibility_snapshot
        update_visibility_columns!(deleted_at: at)
        clear_visibility_patch!
        emit_visibility_changed_event!(from: from, to: visibility_snapshot, source: "strict", action: "soft_delete")
      end
    end

    def can_soft_delete?
      visibility_mutation_allowed_now? && !deleted?
    end

    def restore!
      graph.with_graph_lock! do
        assert_visibility_mutation_allowed!
        from = visibility_snapshot
        update_visibility_columns!(deleted_at: nil)
        clear_visibility_patch!
        emit_visibility_changed_event!(from: from, to: visibility_snapshot, source: "strict", action: "restore")
      end
    end

    def can_restore?
      visibility_mutation_allowed_now? && deleted?
    end

    def request_exclude_from_context!(at: Time.current)
      request_visibility_patch!(
        context_excluded_at: at,
        deleted_at: KEEP,
        action: "exclude_from_context"
      )
    end

    def request_include_in_context!
      request_visibility_patch!(
        context_excluded_at: nil,
        deleted_at: KEEP,
        action: "include_in_context"
      )
    end

    def request_soft_delete!(at: Time.current)
      request_visibility_patch!(
        context_excluded_at: KEEP,
        deleted_at: at,
        action: "soft_delete"
      )
    end

    def request_restore!
      request_visibility_patch!(
        context_excluded_at: KEEP,
        deleted_at: nil,
        action: "restore"
      )
    end

    def mark_running!
      transition_to!(RUNNING, from_states: [PENDING], started_at: Time.current)
    end

    def mark_finished!(content: nil, payload: nil, metadata: {})
      updates = {
        finished_at: Time.current,
        metadata: self.metadata.merge(metadata),
      }

      transitioned = transition_to!(FINISHED, from_states: [RUNNING], **updates)

      if transitioned
        if payload.is_a?(Hash)
          body.merge_output!(payload)
          body.save!
        elsif !content.nil?
          body.apply_finished_content!(content)
          body.save!
        end

        stats = compute_output_stats
        update_columns(
          metadata: self.metadata.merge("output_stats" => stats),
          updated_at: Time.current
        )
      end

      transitioned
    end

    def mark_errored!(error:, metadata: {})
      transition_to!(
        ERRORED,
        from_states: [RUNNING],
        finished_at: Time.current,
        metadata: self.metadata.merge(metadata).merge("error" => error.to_s)
      )
    end

    def mark_rejected!(reason:, metadata: {})
      transition_to!(
        REJECTED,
        from_states: [RUNNING],
        finished_at: Time.current,
        metadata: self.metadata.merge(metadata).merge("reason" => reason.to_s)
      )
    end

    def mark_skipped!(reason: nil, metadata: {})
      reason_metadata = reason ? { "reason" => reason.to_s } : {}
      transition_to!(
        SKIPPED,
        from_states: [PENDING],
        finished_at: Time.current,
        metadata: self.metadata.merge(metadata).merge(reason_metadata)
      )
    end

    def mark_cancelled!(reason: nil, metadata: {})
      reason_metadata = reason ? { "reason" => reason.to_s } : {}
      transition_to!(
        CANCELLED,
        from_states: [RUNNING],
        finished_at: Time.current,
        metadata: self.metadata.merge(metadata).merge(reason_metadata)
      )
    end

    def retry!
      new_node = nil

      graph.mutate! do |m|
        new_node = m.retry_replace!(node: self)
      end

      new_node
    end

    def can_retry?
      return false if compressed_at.present?
      return false unless body&.retriable?
      return false unless [ERRORED, REJECTED, CANCELLED].include?(state)

      descendant_ids = active_causal_descendant_ids - [id]
      if graph.nodes.active.where(id: descendant_ids).where.not(state: PENDING).exists?
        return false
      end

      outgoing_blocking_edges = active_outgoing_blocking_edges
      return true if outgoing_blocking_edges.empty?

      child_states =
        graph.nodes.active.where(id: outgoing_blocking_edges.map(&:to_node_id)).pluck(:id, :state).to_h
      outgoing_blocking_edges.all? { |edge| child_states[edge.to_node_id] == PENDING }
    end

      def rerun!(metadata_patch: {}, body_input_patch: {})
        new_node = nil

      graph.mutate! do |m|
        new_node =
          m.rerun_replace!(
            node: self,
            metadata_patch: metadata_patch,
            body_input_patch: body_input_patch
          )
      end

        new_node
      end

      def can_rerun?
        return false if compressed_at.present?
        return false unless body&.rerunnable?
        return false unless state == FINISHED

        active_outgoing_blocking_edges.empty?
      end

      def versions(include_inactive: true)
        version_set = effective_version_set_id

      scope = graph.nodes.where(version_set_id: version_set)
      scope = scope.active unless include_inactive

      scope.order(:created_at, :id)
    end

    def version_count(include_inactive: true)
      versions(include_inactive: include_inactive).count
    end

    def version_number(include_inactive: true)
      ids = versions(include_inactive: include_inactive).pluck(:id)
      index = ids.index(id)

      if index
        index + 1
      end
    end

    def adopt_version!
      adopted = nil

      graph.mutate! do |m|
        adopted = m.adopt_version!(node: self)
      end

      adopted
    end

    def edit!(new_input:)
      new_node = nil

      graph.mutate! do |m|
        new_node = m.edit_replace!(node: self, new_input: new_input)
      end

      new_node
    end

    def can_edit?
      return false if compressed_at.present?
      return false unless body&.editable?
      return false unless state == FINISHED

      descendant_ids = active_causal_descendant_ids - [id]
      graph.nodes.active.where(id: descendant_ids, state: [PENDING, RUNNING]).none?
    end

    def fork!(node_type:, state:, body_input: {}, body_output: {}, metadata: {})
      new_node = nil

      graph.mutate! do |m|
        new_node = m.fork_from!(
          from_node: self,
          node_type: node_type,
          state: state,
          body_input: body_input,
          body_output: body_output,
          metadata: metadata
        )
      end

      new_node
    end

    def can_fork?
      compressed_at.nil? && terminal?
    end

    def body_input
      if body.present?
        body.input.is_a?(Hash) ? body.input : {}
      else
        @pending_body_input || {}
      end
    end

    def body_input=(hash)
      normalized = hash.is_a?(Hash) ? hash.deep_stringify_keys : {}

      if body.present?
        body.input = normalized
      else
        @pending_body_input = normalized
        ensure_body
      end
    end

    def body_output
      if body.present?
        body.output.is_a?(Hash) ? body.output : {}
      else
        @pending_body_output || {}
      end
    end

    def body_output=(hash)
      normalized = hash.is_a?(Hash) ? hash.deep_stringify_keys : {}

      if body.present?
        body.output = normalized
      else
        @pending_body_output = normalized
        ensure_body
      end
    end

    def body_output_preview
      body.output_preview.is_a?(Hash) ? body.output_preview : {}
    end

    private

      KEEP = :keep

      def effective_version_set_id
        if version_set_id.present?
          version_set_id
        else
          graph&.nodes&.where(id: id)&.pick(:version_set_id)
        end
      end

      def ensure_lane
        return if lane_id.present?
        return if graph.blank?

        if turn_id.present?
          existing_lane_id =
            graph.nodes.active.where(turn_id: turn_id).pick(:lane_id)
          if existing_lane_id.present?
            self.lane_id = existing_lane_id
            return
          end
        end

        self.lane_id = graph.main_lane.id
      end

      def ensure_body
        return if body.present?
        return if node_type.blank?
        return if graph.blank?

        begin
          self.body = graph.body_class_for_node_type(node_type).new
          apply_pending_body_io!
        rescue KeyError, ArgumentError
          errors.add(:node_type, "is unknown")
        end
      end

      def body_type_matches_node_type
        return if node_type.blank? || body.blank?
        return if graph.blank?

        expected_body_class =
          begin
            graph.body_class_for_node_type(node_type)
          rescue KeyError, ArgumentError
            errors.add(:node_type, "is unknown")
            return
          end
        return if body.is_a?(expected_body_class)

        errors.add(:body, "must be a #{expected_body_class.name} for node_type=#{node_type}")
      end

      def pending_or_running_requires_executable_body
        return unless state.in?([PENDING, RUNNING])
        return if body&.executable?

        errors.add(:state, "can only be pending/running for executable nodes")
      end

      def turn_lane_must_be_consistent
        return if graph.blank?
        return if turn_id.blank?
        return if lane_id.blank?

        mismatch =
          graph.nodes.active
            .where(turn_id: turn_id)
            .where.not(id: id)
            .where.not(lane_id: lane_id)
            .exists?
        return unless mismatch

        errors.add(:lane_id, "must match existing nodes for this turn")
      end

      def ensure_turn_record!
        turn = graph.turns.find_by(id: turn_id)

        if turn.nil?
          begin
            turn =
              graph.turns.create!(
                id: turn_id,
                lane_id: lane_id,
                anchor_node_id: nil,
                anchor_created_at: nil,
                metadata: {}
              )
          rescue ActiveRecord::RecordNotUnique
            turn = graph.turns.find_by(id: turn_id)
          end
        end

        raise "turn record is missing after create" if turn.nil?
        if turn.lane_id.to_s != lane_id.to_s
          raise "turn.lane_id mismatch turn_id=#{turn_id} expected=#{lane_id} actual=#{turn.lane_id}"
        end

        return unless body&.class&.turn_anchor?

        now = Time.current

        turn.with_lock do
          current_anchor_at = turn.anchor_created_at
          current_anchor_id = turn.anchor_node_id

          replace =
            current_anchor_at.nil? ||
              created_at < current_anchor_at ||
              (created_at == current_anchor_at && id.to_s < current_anchor_id.to_s)

          if replace
            turn.update_columns(
              anchor_node_id: id,
              anchor_created_at: created_at,
              updated_at: now
            )
          end
        end
      end

      def lane_must_be_writable
        return if lane.blank?
        return if lane.archived_at.blank?

        if turn_id.present? && lane.nodes.active.where(turn_id: turn_id).exists?
          return
        end

        errors.add(:lane, "is archived")
      end

      def visibility_mutation_allowed_now?
        return false if graph.nil?

        graph.visibility_mutation_allowed?(node: self, graph: graph)
      end

      def assert_visibility_mutation_allowed!
        raise ArgumentError, "graph is missing or misconfigured" if graph.nil?

        reason = graph.visibility_mutation_error(node: self, graph: graph)
        return if reason.nil?

        raise ArgumentError, reason
      end

      def active_causal_descendant_ids
        self.class.with_connection do |connection|
          node_quoted = connection.quote(id)
          graph_quoted = connection.quote(graph_id)

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

      def active_outgoing_blocking_edges
        graph.edges.active
          .where(from_node_id: id, edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)
          .where(to_node_id: graph.nodes.active.select(:id))
          .to_a
      end

      def compute_output_stats
        output_bytes, output_preview_bytes =
          DAG::NodeBody.where(id: body_id).pick(
            Arel.sql("pg_column_size(output)"),
            Arel.sql("pg_column_size(output_preview)")
          )

        output_hash = body.output.is_a?(Hash) ? body.output : {}
        stats = {
          "body_output_bytes" => output_bytes.to_i,
          "body_output_preview_bytes" => output_preview_bytes.to_i,
          "output_top_level_keys" => output_hash.size,
        }

        return stats unless output_hash.key?("result")

        result = output_hash["result"]
        stats["result_type"] = json_type_for_stats(result)
        stats["result_key_count"] = result.size if result.is_a?(Hash)
        stats["result_array_len"] = result.length if result.is_a?(Array)

        stats
      end

      def json_type_for_stats(value)
        case value
        when String
          "string"
        when Hash
          "hash"
        when Array
          "array"
        when Numeric
          "number"
        when TrueClass, FalseClass
          "boolean"
        when NilClass
          "null"
        else
          "other"
        end
      end

      def request_visibility_patch!(context_excluded_at:, deleted_at:, action:)
        outcome = nil

        graph.with_graph_lock! do
          from = visibility_snapshot

          if graph.visibility_mutation_allowed?(node: self, graph: graph)
            patch = DAG::NodeVisibilityPatch.where(graph_id: graph_id, node_id: id).lock.first

            base_context_excluded_at = patch ? patch.context_excluded_at : self.context_excluded_at
            base_deleted_at = patch ? patch.deleted_at : self.deleted_at

            desired_context_excluded_at =
              context_excluded_at == KEEP ? base_context_excluded_at : context_excluded_at
            desired_deleted_at = deleted_at == KEEP ? base_deleted_at : deleted_at

            update_visibility_columns!(
              context_excluded_at: desired_context_excluded_at,
              deleted_at: desired_deleted_at
            )

            patch&.destroy!
            emit_visibility_changed_event!(from: from, to: visibility_snapshot, source: "request_applied", action: action)
            outcome = :applied
          else
            desired = upsert_visibility_patch!(context_excluded_at: context_excluded_at, deleted_at: deleted_at)

            graph.emit_event(
              event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_CHANGE_REQUESTED,
              subject: self,
              particulars: {
                "action" => action,
                "desired" => desired,
                "reason" => graph.visibility_mutation_error(node: self, graph: graph),
              }
            )
            outcome = :deferred
          end
        end

        graph.kick! if outcome == :deferred

        outcome
      end

      def upsert_visibility_patch!(context_excluded_at:, deleted_at:)
        patch_scope = DAG::NodeVisibilityPatch.where(graph_id: graph_id, node_id: id).lock
        patch = patch_scope.first

        base_context_excluded_at = patch ? patch.context_excluded_at : self.context_excluded_at
        base_deleted_at = patch ? patch.deleted_at : self.deleted_at

        desired_context_excluded_at =
          context_excluded_at == KEEP ? base_context_excluded_at : context_excluded_at
        desired_deleted_at = deleted_at == KEEP ? base_deleted_at : deleted_at

        if patch
          patch.update!(
            context_excluded_at: desired_context_excluded_at,
            deleted_at: desired_deleted_at
          )
        else
          DAG::NodeVisibilityPatch.create!(
            graph_id: graph_id,
            node_id: id,
            context_excluded_at: desired_context_excluded_at,
            deleted_at: desired_deleted_at
          )
        end

        visibility_snapshot_for(context_excluded_at: desired_context_excluded_at, deleted_at: desired_deleted_at)
      end

      def clear_visibility_patch!
        DAG::NodeVisibilityPatch.where(graph_id: graph_id, node_id: id).delete_all
      end

      def update_visibility_columns!(context_excluded_at: KEEP, deleted_at: KEEP)
        now = Time.current

        updates = { updated_at: now }
        updates[:context_excluded_at] = context_excluded_at unless context_excluded_at == KEEP
        updates[:deleted_at] = deleted_at unless deleted_at == KEEP

        update_columns(updates)
      end

      def apply_pending_body_io!
        pending_body_input = @pending_body_input
        pending_body_output = @pending_body_output
        @pending_body_input = nil
        @pending_body_output = nil

        body.input = pending_body_input if pending_body_input.present?
        body.output = pending_body_output if pending_body_output.present?
      end

      def visibility_snapshot
        visibility_snapshot_for(context_excluded_at: context_excluded_at, deleted_at: deleted_at)
      end

      def visibility_snapshot_for(context_excluded_at:, deleted_at:)
        {
          "context_excluded_at" => context_excluded_at&.iso8601,
          "deleted_at" => deleted_at&.iso8601,
        }
      end

      def emit_visibility_changed_event!(from:, to:, source:, action:)
        return if from == to

        graph.emit_event(
          event_type: DAG::GraphHooks::EventTypes::NODE_VISIBILITY_CHANGED,
          subject: self,
          particulars: {
            "action" => action,
            "source" => source,
            "from" => from,
            "to" => to,
          }
        )
      end

      def transition_to!(to_state, from_states:, **attributes)
        now = Time.current
        updates = attributes.merge(state: to_state, updated_at: now)
        affected_rows = self.class.where(id: id, state: from_states).update_all(updates)

        if affected_rows == 1
          reload
          true
        else
          false
        end
      end
  end
end
