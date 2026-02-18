module DAG
  class Node < ApplicationRecord
    self.table_name = "dag_nodes"

    USER_MESSAGE = "user_message"
    AGENT_MESSAGE = "agent_message"
    TASK = "task"
    SUMMARY = "summary"

    PENDING = "pending"
    RUNNING = "running"
    FINISHED = "finished"
    ERRORED = "errored"
    REJECTED = "rejected"
    SKIPPED = "skipped"
    CANCELLED = "cancelled"

    NODE_TYPES = [USER_MESSAGE, AGENT_MESSAGE, TASK, SUMMARY].freeze
    STATES = [PENDING, RUNNING, FINISHED, ERRORED, REJECTED, SKIPPED, CANCELLED].freeze
    TERMINAL_STATES = [FINISHED, ERRORED, REJECTED, SKIPPED, CANCELLED].freeze
    EXECUTABLE_NODE_TYPES = [TASK, AGENT_MESSAGE].freeze

    enum :node_type, NODE_TYPES.index_by(&:itself)
    enum :state, STATES.index_by(&:itself)

    belongs_to :graph, class_name: "DAG::Graph", inverse_of: :nodes
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

    validates :node_type, inclusion: { in: NODE_TYPES }
    validates :state, inclusion: { in: STATES }
    validate :body_type_matches_node_type

    scope :active, -> { where(compressed_at: nil) }

    before_validation :ensure_body

    def pending?
      state == PENDING
    end

    def running?
      state == RUNNING
    end

    def finished?
      state == FINISHED
    end

    def terminal?
      TERMINAL_STATES.include?(state)
    end

    def executable?
      EXECUTABLE_NODE_TYPES.include?(node_type)
    end

    def context_excluded?
      context_excluded_at.present?
    end

    def deleted?
      deleted_at.present?
    end

    def exclude_from_context!(at: Time.current)
      graph.with_graph_lock! do
        assert_visibility_mutation_allowed!
        update_visibility_columns!(context_excluded_at: at)
        clear_visibility_patch!
      end
    end

    def can_exclude_from_context?
      visibility_mutation_allowed_now? && !context_excluded?
    end

    def include_in_context!
      graph.with_graph_lock! do
        assert_visibility_mutation_allowed!
        update_visibility_columns!(context_excluded_at: nil)
        clear_visibility_patch!
      end
    end

    def can_include_in_context?
      visibility_mutation_allowed_now? && context_excluded?
    end

    def soft_delete!(at: Time.current)
      graph.with_graph_lock! do
        assert_visibility_mutation_allowed!
        update_visibility_columns!(deleted_at: at)
        clear_visibility_patch!
      end
    end

    def can_soft_delete?
      visibility_mutation_allowed_now? && !deleted?
    end

    def restore!
      graph.with_graph_lock! do
        assert_visibility_mutation_allowed!
        update_visibility_columns!(deleted_at: nil)
        clear_visibility_patch!
      end
    end

    def can_restore?
      visibility_mutation_allowed_now? && deleted?
    end

    def request_exclude_from_context!(at: Time.current)
      request_visibility_patch!(context_excluded_at: at, deleted_at: KEEP)
    end

    def request_include_in_context!
      request_visibility_patch!(context_excluded_at: nil, deleted_at: KEEP)
    end

    def request_soft_delete!(at: Time.current)
      request_visibility_patch!(context_excluded_at: KEEP, deleted_at: at)
    end

    def request_restore!
      request_visibility_patch!(context_excluded_at: KEEP, deleted_at: nil)
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

    def regenerate!
      new_node = nil

      graph.mutate! do |m|
        new_node = m.regenerate_replace!(node: self)
      end

      new_node
    end

    def can_regenerate?
      return false if compressed_at.present?
      return false unless body&.regeneratable?
      return false unless state == FINISHED

      active_outgoing_blocking_edges.empty?
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

      def ensure_body
        return if body.present?
        return if node_type.blank?
        return if graph.blank?

        self.body = graph_policy.body_class_for_node_type(node_type).new
        apply_pending_body_io!
      end

      def body_type_matches_node_type
        return if node_type.blank? || body.blank?

        expected_body_class = graph_policy.body_class_for_node_type(node_type)
        return if body.is_a?(expected_body_class)

        errors.add(:body, "must be a #{expected_body_class.name} for node_type=#{node_type}")
      end

      def graph_policy
        graph&.policy || DAG::GraphPolicies::Default.new
      end

      def visibility_mutation_allowed_now?
        terminal? && graph.nodes.active.where(state: RUNNING).none?
      end

      def assert_visibility_mutation_allowed!
        raise ArgumentError, "can only change visibility for terminal nodes" unless terminal?

        if graph.nodes.active.where(state: RUNNING).exists?
          raise ArgumentError, "cannot change visibility while graph has running nodes"
        end
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

      def request_visibility_patch!(context_excluded_at:, deleted_at:)
        outcome = nil

        graph.with_graph_lock! do
          graph_idle = !graph.nodes.active.where(state: RUNNING).exists?

          if graph_idle && terminal?
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
            outcome = :applied
          else
            upsert_visibility_patch!(context_excluded_at: context_excluded_at, deleted_at: deleted_at)
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
