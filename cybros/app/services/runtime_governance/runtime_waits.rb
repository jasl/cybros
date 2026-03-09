module RuntimeGovernance
  module RuntimeWaits
    module_function

    def park!(owner_type:, owner_id:, reason_type:, subject_type:, subject_id:, retry_at:, details:, now: Time.current)
      existing =
        RuntimeWait.parked.find_by(
          owner_type: owner_type,
          owner_id: owner_id,
          reason_type: reason_type,
          subject_type: subject_type,
          subject_id: subject_id,
        )
      return existing if existing

      RuntimeWait.create!(
        owner_type: owner_type,
        owner_id: owner_id,
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
        retry_at: retry_at,
        ordering_key: ordering_key_for(now: now),
        details: details,
        status: "parked",
      )
    rescue ActiveRecord::RecordNotUnique
      RuntimeWait.parked.find_by!(
        owner_type: owner_type,
        owner_id: owner_id,
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      )
    end

    def next_ready(reason_type:, subject_type:, subject_id:, now: Time.current)
      RuntimeWait.parked.where(
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      ).where("retry_at <= ?", now).order(:ordering_key, :created_at, :id).first
    end

    def next_parked(reason_type:, subject_type:, subject_id:)
      RuntimeWait.parked.where(
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      ).order(:ordering_key, :created_at, :id).first
    end

    def resume!(wait:, now: Time.current)
      resumed =
        wait.with_lock do
          wait.reload
          next wait unless wait.status == "parked"

          wait.update!(status: "resumed")
          wait
        end

      wake_owner!(wait: resumed, now: now)
      resumed
    end

    def resume_next_parked!(reason_type:, subject_type:, subject_id:, now: Time.current)
      wait = next_parked(reason_type: reason_type, subject_type: subject_type, subject_id: subject_id)
      return nil if wait.nil?

      resume!(wait: wait, now: now)
    end

    def wake_owner!(wait:, now:)
      return unless wait.reason_type == "execution_capacity" && wait.owner_type == "ConversationRun"

      run = ConversationRun.find_by(id: wait.owner_id)
      return if run.nil?

      graph = run.conversation&.root_graph
      return if graph.nil?

      node = graph.nodes.find_by(id: run.dag_node_id)
      return unless node&.pending?

      metadata = node.metadata.is_a?(Hash) ? node.metadata.deep_stringify_keys : {}
      runtime_wait = metadata["runtime_wait"]
      return unless runtime_wait.is_a?(Hash) && runtime_wait["runtime_wait_id"].to_s == wait.id.to_s

      updated =
        DAG::Node.where(id: node.id, graph_id: graph.id, state: DAG::Node::PENDING).update_all(
          claim_after_at: nil,
          metadata: metadata.except("runtime_wait"),
          updated_at: now,
        )

      graph.kick! if updated == 1

      wait
    end

    def cancel!(owner_type:, owner_id:, reason_type:, subject_type:, subject_id:)
      RuntimeWait.parked.where(
        owner_type: owner_type,
        owner_id: owner_id,
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      ).update_all(status: "cancelled", updated_at: Time.current)
    end

    def parked_count(reason_type:, subject_type:, subject_id:)
      RuntimeWait.parked.where(
        reason_type: reason_type,
        subject_type: subject_type,
        subject_id: subject_id,
      ).count
    end

    def ordering_key_for(now:)
      "#{now.utc.iso8601(6)}:#{SecureRandom.uuid}"
    end
    private_class_method :ordering_key_for, :wake_owner!
  end
end
