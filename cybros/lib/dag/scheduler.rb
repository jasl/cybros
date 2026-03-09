module DAG
  class Scheduler
    ClaimOutcome = Struct.new(:node, :events, :node_id, keyword_init: true)

    def self.claim_executable_nodes(graph:, limit:, claimed_by:)
      new(graph: graph, limit: limit, claimed_by: claimed_by).claim_executable_nodes
    end

    def self.claim_pending_node!(graph:, node:, claimed_by:, now: Time.current)
      new(graph: graph, limit: 1, claimed_by: claimed_by).claim_pending_node!(node: node, now: now)
    end

    def initialize(graph:, limit:, claimed_by:)
      @graph = graph
      @graph_id = graph.id
      @limit = Integer(limit)
      @claimed_by = claimed_by.to_s
    end

    def claim_executable_nodes
      claimed_nodes = []
      processed_ids = []
      events = []

      while claimed_nodes.length < @limit
        outcome = next_claimable_outcome(processed_ids: processed_ids)
        break if outcome.nil?

        processed_ids << outcome.node_id
        claimed_nodes << outcome.node if outcome.node.present?
        events.concat(outcome.events)
      end

      emit_events(events)
      claimed_nodes
    end

    def claim_pending_node!(node:, now: Time.current)
      outcome =
        claim_transaction do
          locked_node = DAG::Node.lock.find_by(id: node.id, graph_id: @graph_id)
          next nil if locked_node.nil?

          attempt_claim_locked!(node: locked_node, now: now)
        end

      emit_events(outcome.events) if outcome.present?
      outcome&.node
    end

    private

      def next_claimable_outcome(processed_ids:)
        now = Time.current

        claim_transaction do |connection|
          node_id = next_candidate_id(connection: connection, now: now, processed_ids: processed_ids)
          next nil if node_id.nil?

          node = DAG::Node.find(node_id)
          attempt_claim_locked!(node: node, now: now)
        end
      end

      def claim_transaction
        DAG::Node.with_connection do |connection|
          DAG::Node.transaction do
            yield connection
          end
        end
      end

      def next_candidate_id(connection:, now:, processed_ids:)
        graph_quoted = connection.quote(@graph_id)
        processed_sql =
          if processed_ids.any?
            quoted_ids = processed_ids.map { |id| connection.quote(id) }.join(", ")
            "AND dag_nodes.id NOT IN (#{quoted_ids})"
          else
            ""
          end

        sql = <<~SQL
          SELECT dag_nodes.id
          FROM dag_nodes
          WHERE dag_nodes.graph_id = #{graph_quoted}
            AND dag_nodes.state = 'pending'
            AND dag_nodes.compressed_at IS NULL
            AND (dag_nodes.claim_after_at IS NULL OR dag_nodes.claim_after_at <= #{connection.quote(now)})
            #{processed_sql}
            AND NOT EXISTS (
              SELECT 1
              FROM dag_edges
              JOIN dag_nodes AS parents
                ON parents.id = dag_edges.from_node_id
               AND parents.graph_id = dag_edges.graph_id
              WHERE dag_edges.graph_id = dag_nodes.graph_id
                AND dag_edges.to_node_id = dag_nodes.id
                AND dag_edges.edge_type IN ('sequence', 'dependency')
                AND dag_edges.compressed_at IS NULL
                AND parents.compressed_at IS NULL
                AND (
                  (
                    dag_edges.edge_type = 'sequence'
                    AND parents.state NOT IN ('finished', 'errored', 'rejected', 'skipped', 'stopped')
                  )
                  OR (
                    dag_edges.edge_type = 'dependency'
                    AND parents.state <> 'finished'
                  )
                )
            )
          ORDER BY dag_nodes.id
          FOR UPDATE SKIP LOCKED
          LIMIT 1
        SQL

        connection.select_value(sql)
      end

      def attempt_claim_locked!(node:, now:)
        run = ConversationRun.latest_for_node(node)

        if run&.execution_capacity_governed?
          admission = RuntimeGovernance::ExecutionCapacityEnforcer.admit!(conversation_run: run, now: now)

          case admission.fetch(:decision)
          when "acquired"
            return claim_node_locked!(node: node, now: now)
          when "parked"
            park_node_for_capacity_wait!(node: node, runtime_wait: admission.fetch(:runtime_wait), now: now)
            return ClaimOutcome.new(node: nil, node_id: node.id, events: [])
          when "denied"
            return fail_node_for_capacity_denial!(node: node, now: now)
          end
        end

        claim_node_locked!(node: node, now: now)
      end

      def claim_node_locked!(node:, now:)
        lease_seconds = @graph.claim_lease_seconds_for(nil)
        lease_expires_at = now + lease_seconds
        metadata = node.metadata.is_a?(Hash) ? node.metadata.deep_stringify_keys.except("runtime_wait") : {}

        affected_rows =
          DAG::Node.where(id: node.id, state: DAG::Node::PENDING).update_all(
            state: DAG::Node::RUNNING,
            claim_after_at: nil,
            started_at: nil,
            claimed_at: now,
            claimed_by: @claimed_by,
            lease_expires_at: lease_expires_at,
            heartbeat_at: nil,
            metadata: metadata,
            updated_at: now
          )

        return ClaimOutcome.new(node: nil, node_id: node.id, events: []) unless affected_rows == 1

        ClaimOutcome.new(
          node: DAG::Node.find(node.id),
          node_id: node.id,
          events: [{ node_id: node.id, from: "pending", to: "running" }],
        )
      end

      def park_node_for_capacity_wait!(node:, runtime_wait:, now:)
        metadata = node.metadata.is_a?(Hash) ? node.metadata.deep_stringify_keys : {}
        metadata["runtime_wait"] = {
          "reason_type" => runtime_wait.reason_type,
          "runtime_wait_id" => runtime_wait.id,
          "retry_at" => runtime_wait.retry_at&.iso8601(6),
          "details" => runtime_wait.details,
        }.compact

        DAG::Node.where(id: node.id, state: DAG::Node::PENDING).update_all(
          claim_after_at: runtime_wait.retry_at,
          metadata: metadata,
          updated_at: now
        )
      end

      def fail_node_for_capacity_denial!(node:, now:)
        denied = node.fail_pending!(error: "execution_capacity_denied")
        ConversationRunTracker.mark_terminal_for_node!(node, at: node.finished_at || now) if denied

        ClaimOutcome.new(
          node: nil,
          node_id: node.id,
          events: denied ? [{ node_id: node.id, from: "pending", to: "errored" }] : [],
        )
      end

      def emit_events(events)
        events.each do |event|
          @graph.emit_event(
            event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
            subject_type: "DAG::Node",
            subject_id: event.fetch(:node_id),
            particulars: { "from" => event.fetch(:from), "to" => event.fetch(:to) }
          )
        end
      end
  end
end
