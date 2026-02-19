module DAG
  class Runner
    def self.run_node!(node_id, execute_job_id: nil)
      new(node_id: node_id, execute_job_id: execute_job_id).run_node!
    end

    def initialize(node_id:, execute_job_id: nil)
      @node_id = node_id
      @execute_job_id = execute_job_id
    end

    def run_node!
      stream = nil

      node = DAG::Node.find_by(id: @node_id)
      return if node.nil?
      return unless node.running?

      graph = node.graph
      return if node.lease_expires_at.present? && node.lease_expires_at < Time.current

      return unless refresh_running_lease!(node)

      context = graph.context_for(node.id)

      stream = DAG::NodeEventStream.new(node: node)
      result = DAG.executor_registry.execute(node: node, context: context, stream: stream)

      stream.flush!

      if result.streamed_output? || result.state == DAG::Node::STOPPED
        streamed_output = streamed_output_for(node)
      end
      graph.with_graph_lock! do
        apply_result(node, result, streamed_output: streamed_output)
        DAG::FailurePropagation.propagate!(graph: graph)
        graph.validate_leaf_invariant!
      end
    rescue StandardError => error
      if node
        graph = node.graph
        graph.with_graph_lock! do
          apply_result(node, DAG::ExecutionResult.errored(error: "#{error.class}: #{error.message}"))
          DAG::FailurePropagation.propagate!(graph: graph)
          graph.validate_leaf_invariant!
        end
      end
    ensure
      begin
        stream&.flush!
      rescue StandardError => error
        Rails.logger.error(
          "[DAG] node_event_stream_flush_error node_id=#{@node_id} error=#{error.class}: #{error.message}"
        )
      end

      DAG::TickGraphJob.perform_later(node.graph_id) if node
    end

    private

      def refresh_running_lease!(node)
        now = Time.current
        started_at = node.started_at || now
        lease_seconds = node.graph.execution_lease_seconds_for(node)
        lease_expires_at = now + lease_seconds

        affected_rows =
          DAG::Node.where(id: node.id, state: DAG::Node::RUNNING, compressed_at: nil).update_all(
            started_at: started_at,
            heartbeat_at: now,
            lease_expires_at: lease_expires_at,
            updated_at: now
          )

        return false unless affected_rows == 1

        node.reload

        record_execution_start_metadata!(node, now: now)
        true
      end

      def streamed_output_for(node)
        DAG::NodeEvent.with_connection do |connection|
          graph_quoted = connection.quote(node.graph_id)
          node_quoted = connection.quote(node.id)
          kind_quoted = connection.quote(DAG::NodeEvent::OUTPUT_DELTA)

          sql = <<~SQL
            SELECT COALESCE(string_agg(text, '' ORDER BY id), '')
            FROM dag_node_events
            WHERE graph_id = #{graph_quoted}
              AND node_id = #{node_quoted}::uuid
              AND kind = #{kind_quoted}
          SQL

          connection.select_value(sql).to_s
        end
      end

      def apply_result(node, result, streamed_output: nil)
        from_state = node.state
        metadata = normalize_hook_metadata(result.metadata)
        if result.usage.is_a?(Hash) && result.usage.present?
          metadata["usage"] = result.usage.deep_stringify_keys
        end

        transitioned =
          case result.state
          when DAG::Node::FINISHED
            if result.streamed_output?
              if result.content.present? || result.payload.present?
                node.mark_errored!(
                  error: "invalid_execution_result=finished_streamed_with_payload_or_content",
                  metadata: metadata
                )
              else
                node.mark_finished!(content: streamed_output.to_s, metadata: metadata)
              end
            else
              node.mark_finished!(content: result.content, payload: result.payload, metadata: metadata)
            end
          when DAG::Node::ERRORED
            node.mark_errored!(error: result.error || "errored", metadata: metadata)
          when DAG::Node::REJECTED
            node.mark_rejected!(reason: result.reason || "rejected", metadata: metadata)
          when DAG::Node::SKIPPED
            node.mark_errored!(
              error: "invalid_execution_result_state=skipped_for_running_node",
              metadata: metadata.merge("reason" => result.reason)
            )
          when DAG::Node::STOPPED
            stopped = node.mark_stopped!(reason: result.reason, metadata: metadata)
            if stopped && streamed_output.present?
              node.body.apply_finished_content!(streamed_output)
              node.body.save!
            end
            stopped
          else
            node.mark_errored!(error: "unknown_execution_result_state=#{result.state}", metadata: metadata)
          end

        if transitioned
          node.graph.emit_event(
            event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
            subject: node,
            particulars: { "from" => from_state, "to" => node.state }
          )

          record_execution_finished_metadata!(node)
        end
      end

      def normalize_hook_metadata(metadata)
        if metadata.is_a?(Hash)
          metadata.deep_stringify_keys
        else
          {}
        end
      end

      def record_execution_start_metadata!(node, now:)
        timing_patch = {}

        if node.claimed_at.present? && node.started_at.present?
          timing_patch["queue_latency_ms"] = ((node.started_at - node.claimed_at) * 1000).to_i
        end

        worker_patch = {}
        if @execute_job_id.present?
          worker_patch["execute_job_id"] = @execute_job_id.to_s
        end

        return if timing_patch.empty? && worker_patch.empty?

        metadata = node.metadata.is_a?(Hash) ? node.metadata.deep_stringify_keys : {}

        if timing_patch.any?
          timing = metadata["timing"].is_a?(Hash) ? metadata["timing"] : {}
          metadata["timing"] = timing.merge(timing_patch)
        end

        if worker_patch.any?
          worker = metadata["worker"].is_a?(Hash) ? metadata["worker"] : {}
          metadata["worker"] = worker.merge(worker_patch)
        end

        node.update_columns(metadata: metadata, updated_at: now)
      end

      def record_execution_finished_metadata!(node)
        return unless node.started_at.present? && node.finished_at.present?

        timing_patch = {
          "run_duration_ms" => ((node.finished_at - node.started_at) * 1000).to_i,
        }

        if node.claimed_at.present?
          timing_patch["queue_latency_ms"] ||= ((node.started_at - node.claimed_at) * 1000).to_i
        end

        metadata = node.metadata.is_a?(Hash) ? node.metadata.deep_stringify_keys : {}
        timing = metadata["timing"].is_a?(Hash) ? metadata["timing"] : {}
        metadata["timing"] = timing.merge(timing_patch)

        node.update_columns(metadata: metadata, updated_at: Time.current)
      end
  end
end
