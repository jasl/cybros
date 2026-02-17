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

    belongs_to :conversation, inverse_of: :dag_nodes
    belongs_to :runnable,
      polymorphic: true,
      autosave: true,
      dependent: :destroy,
      inverse_of: :dag_node
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
    validates :conversation_id, presence: true

    scope :active, -> { where(compressed_at: nil) }

    before_validation :ensure_runnable

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

    def mark_running!
      transition_to!(RUNNING, from_states: [PENDING], started_at: Time.current)
    end

    def mark_finished!(content: nil, metadata: {})
      updates = {
        finished_at: Time.current,
        metadata: self.metadata.merge(metadata),
      }

      transitioned = transition_to!(FINISHED, from_states: [RUNNING], **updates)

      if transitioned && !content.nil?
        runnable.update!(content: content)
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

    def retry!(branch_kind: "retry")
      unless [ERRORED, REJECTED, SKIPPED, CANCELLED].include?(state)
        raise ArgumentError, "can only retry errored, rejected, skipped, or cancelled nodes"
      end

      conversation.with_graph_lock do
        conversation.transaction do
          attempt = metadata.fetch("attempt", 1).to_i + 1
          new_node = conversation.dag_nodes.create!(
            node_type: node_type,
            state: PENDING,
            metadata: metadata.merge("attempt" => attempt),
            retry_of_id: id,
          )

          conversation.dag_edges.active.where(
            to_node_id: id,
            edge_type: [DAG::Edge::SEQUENCE, DAG::Edge::DEPENDENCY]
          ).find_each do |edge|
            conversation.dag_edges.create!(
              from_node_id: edge.from_node_id,
              to_node_id: new_node.id,
              edge_type: edge.edge_type,
              metadata: edge.metadata
            )
          end

          conversation.dag_edges.create!(
            from_node_id: id,
            to_node_id: new_node.id,
            edge_type: DAG::Edge::BRANCH,
            metadata: { "branch_kinds" => [branch_kind] }
          )

          conversation.record_event!(
            event_type: "node_retried",
            subject: new_node,
            particulars: { "retry_of_id" => id, "branch_kinds" => [branch_kind] }
          )

          new_node
        end
      end
    end

    def content
      runnable.content
    end

    def content=(value)
      ensure_runnable
      runnable.content = value
    end

    def as_context_hash
      {
        "node_id" => id,
        "node_type" => node_type,
        "state" => state,
        "content" => content,
        "metadata" => metadata,
      }
    end

    private

      def ensure_runnable
        return if runnable.present?

        self.runnable =
          if node_type == TASK
            DAG::Runnables::Task.new
          else
            DAG::Runnables::Text.new
          end
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
