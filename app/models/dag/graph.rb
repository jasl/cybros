module DAG
  class Graph < ApplicationRecord
    self.table_name = "dag_graphs"

    LOCK_PREFIX = "dag:advisory:graph".freeze

    belongs_to :attachable, polymorphic: true, optional: true

    has_many :nodes,
             class_name: "DAG::Node",
             inverse_of: :graph
    has_many :edges,
             class_name: "DAG::Edge",
             inverse_of: :graph

    before_destroy :purge_graph_records

    def mutate!
      raise ArgumentError, "block required" unless block_given?

      executable_pending_nodes_created = false

      with_graph_lock! do
        mutations = DAG::Mutations.new(graph: self)
        yield mutations

        executable_pending_nodes_created =
          mutations.executable_pending_nodes_created? || validate_leaf_invariant!
      end

      if executable_pending_nodes_created
        kick!
      end
    end

    def context_for(target_node_id, mode: :preview, include_excluded: false, include_deleted: false)
      DAG::ContextAssembly.new(graph: self).call(
        target_node_id,
        mode: mode,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def context_for_full(target_node_id, include_excluded: false, include_deleted: false)
      context_for(
        target_node_id,
        mode: :full,
        include_excluded: include_excluded,
        include_deleted: include_deleted
      )
    end

    def transcript_for(target_node_id, limit: nil, mode: :preview, include_deleted: false)
      unless include_deleted
        deleted_at = nodes.where(id: target_node_id).pick(:deleted_at)
        return [] if deleted_at.present?
      end

      transcript = context_for(
        target_node_id,
        mode: mode,
        include_excluded: true,
        include_deleted: include_deleted
      ).select do |context_node|
        node_type = context_node["node_type"]

        case node_type
        when DAG::Node::USER_MESSAGE
          true
        when DAG::Node::AGENT_MESSAGE
          state = context_node["state"].to_s
          preview_content = context_node.dig("payload", "output_preview", "content").to_s
          metadata = context_node["metadata"].is_a?(Hash) ? context_node["metadata"] : {}
          transcript_visible = metadata["transcript_visible"] == true

          state.in?([DAG::Node::PENDING, DAG::Node::RUNNING]) || preview_content.present? || transcript_visible
        else
          false
        end
      end

      transcript.each do |context_node|
        next unless context_node["node_type"] == DAG::Node::AGENT_MESSAGE

        payload = context_node["payload"].is_a?(Hash) ? context_node["payload"] : {}
        output_preview = payload["output_preview"].is_a?(Hash) ? payload["output_preview"] : {}
        next if output_preview["content"].to_s.present?

        metadata = context_node["metadata"].is_a?(Hash) ? context_node["metadata"] : {}
        transcript_preview = metadata["transcript_preview"]
        next unless transcript_preview.is_a?(String) && transcript_preview.present?

        output_preview["content"] = transcript_preview.truncate(2000)
        payload["output_preview"] = output_preview
        context_node["payload"] = payload
      end

      if limit
        transcript = transcript.last(Integer(limit))
      end

      transcript
    end

    def transcript_for_full(target_node_id, limit: nil, include_deleted: false)
      transcript_for(
        target_node_id,
        limit: limit,
        mode: :full,
        include_deleted: include_deleted
      )
    end

    def compress!(node_ids:, summary_content:, summary_metadata: {})
      DAG::Compression.new(graph: self).compress!(
        node_ids: node_ids,
        summary_content: summary_content,
        summary_metadata: summary_metadata
      )
    end

    def to_mermaid(include_compressed: false, max_label_chars: 80)
      DAG::Visualization::MermaidExporter.new(
        graph: self,
        include_compressed: include_compressed,
        max_label_chars: max_label_chars
      ).call
    end

    def kick!(limit: 10)
      DAG::TickGraphJob.perform_later(id, limit: limit)
    end

    def apply_visibility_patches_if_idle!
      return 0 if nodes.active.where(state: DAG::Node::RUNNING).exists?

      applied = 0
      now = Time.current

      DAG::NodeVisibilityPatch.where(graph_id: id).order(:updated_at, :id).lock.find_each do |patch|
        node = nodes.find_by(id: patch.node_id)

        if node.nil? || node.compressed_at.present? || node.graph_id != id
          patch.destroy!
          next
        end

        next unless node.terminal?

        node.update_columns(
          context_excluded_at: patch.context_excluded_at,
          deleted_at: patch.deleted_at,
          updated_at: now
        )
        patch.destroy!
        applied += 1
      end

      applied
    end

    def hooks
      key = attachable_cache_key
      if defined?(@hooks_cache_key) && @hooks_cache_key == key
        return @hooks
      end

      @hooks_cache_key = key

      @hooks =
        if attachable&.respond_to?(:dag_graph_hooks)
          attachable.dag_graph_hooks || DAG::GraphHooks::NOOP
        else
          DAG::GraphHooks::NOOP
        end
    end

    def policy
      key = attachable_cache_key
      if defined?(@policy_cache_key) && @policy_cache_key == key
        return @policy
      end

      @policy_cache_key = key

      @policy =
        if attachable&.respond_to?(:dag_graph_policy)
          attachable.dag_graph_policy || DAG::GraphPolicies::Default.new
        else
          DAG::GraphPolicies::Default.new
        end
    end

    def emit_event(event_type:, particulars: {}, subject: nil, subject_type: nil, subject_id: nil)
      event_type = event_type.to_s
      validate_event_type!(event_type)

      if subject
        subject_type = subject.class.name
        subject_id = subject.id
      end

      raise ArgumentError, "subject_type required" if subject_type.blank?
      raise ArgumentError, "subject_id required" if subject_id.blank?

      begin
        hooks.record_event(
          graph: self,
          event_type: event_type,
          subject_type: subject_type,
          subject_id: subject_id,
          particulars: particulars
        )
      rescue StandardError => error
        Rails.logger.error(
          "[DAG] graph_hooks_error graph_id=#{id} event_type=#{event_type} " \
          "subject_type=#{subject_type} subject_id=#{subject_id} error=#{error.class}: #{error.message}"
        )
        nil
      end
    end

    def advisory_lock_name
      raise "graph must be persisted" if id.blank?

      "#{LOCK_PREFIX}:#{id}"
    end

    def with_graph_lock!(&block)
      raise ArgumentError, "block required" unless block_given?

      self.class.with_advisory_lock!(advisory_lock_name) do
        transaction do
          lock!
          yield
        end
      end
    end

    def with_graph_try_lock(&block)
      raise ArgumentError, "block required" unless block_given?

      self.class.with_advisory_lock(advisory_lock_name, timeout_seconds: 0) do
        transaction do
          lock!
          return yield
        end
      end

      false
    end

    def validate_leaf_invariant!
      created_nodes = false

      leaf_nodes.each do |leaf|
        next if policy.leaf_valid?(leaf)

        repaired_node = nodes.create!(policy.leaf_repair_node_attributes(leaf))
        edges.create!(
          policy.leaf_repair_edge_attributes(leaf, repaired_node).merge(
            from_node_id: leaf.id,
            to_node_id: repaired_node.id
          )
        )

        emit_event(
          event_type: DAG::GraphHooks::EventTypes::LEAF_INVARIANT_REPAIRED,
          subject: repaired_node,
          particulars: { "leaf_node_id" => leaf.id }
        )

        created_nodes = true
      end

      created_nodes
    end

    def leaf_nodes(include_compressed: false)
      nodes_scope = nodes
      edges_scope = edges.where(edge_type: DAG::Edge::BLOCKING_EDGE_TYPES)

      unless include_compressed
        nodes_scope = nodes_scope.where(compressed_at: nil)
        edges_scope = edges_scope.where(compressed_at: nil)
        edges_scope = edges_scope.where(to_node_id: nodes_scope.select(:id))
      end

      nodes_scope.where.not(id: edges_scope.select(:from_node_id))
    end

    private

      def attachable_cache_key
        [attachable_type, attachable_id]
      end

      def validate_event_type!(event_type)
        return if DAG::GraphHooks::EventTypes::ALL.include?(event_type)

        raise ArgumentError,
              "unknown DAG graph hook event_type=#{event_type.inspect}. " \
              "Add it to DAG::GraphHooks::EventTypes and update docs/spec."
      end

      def purge_graph_records
        self.class.with_connection do |connection|
          graph_id_quoted = connection.quote(id)

          connection.delete(<<~SQL.squish, "purge_dag_visibility_patches")
            DELETE FROM dag_node_visibility_patches WHERE graph_id = #{graph_id_quoted}
          SQL

          connection.delete(<<~SQL.squish, "purge_dag_edges")
            DELETE FROM dag_edges WHERE graph_id = #{graph_id_quoted}
          SQL

          connection.delete(<<~SQL.squish, "purge_dag_nodes_and_bodies")
            WITH deleted_nodes AS (
              DELETE FROM dag_nodes WHERE graph_id = #{graph_id_quoted}
              RETURNING body_id
            )
            DELETE FROM dag_node_bodies
            USING deleted_nodes
            WHERE dag_node_bodies.id = deleted_nodes.body_id
          SQL
        end
      end
  end
end
