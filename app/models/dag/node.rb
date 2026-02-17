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

    def regenerate!
      new_node = nil

      graph.mutate! do |m|
        new_node = m.regenerate_replace!(node: self)
      end

      new_node
    end

    def edit!(new_input:)
      new_node = nil

      graph.mutate! do |m|
        new_node = m.edit_replace!(node: self, new_input: new_input)
      end

      new_node
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

    def body_input
      body.input.is_a?(Hash) ? body.input : {}
    end

    def body_input=(hash)
      ensure_body
      body.input = hash.is_a?(Hash) ? hash.deep_stringify_keys : {}
    end

    def body_output
      body.output.is_a?(Hash) ? body.output : {}
    end

    def body_output=(hash)
      ensure_body
      body.output = hash.is_a?(Hash) ? hash.deep_stringify_keys : {}
    end

    def body_output_preview
      body.output_preview.is_a?(Hash) ? body.output_preview : {}
    end

    private

      def ensure_body
        return if body.present?
        return if node_type.blank?

        self.body = body_class_for_node_type.new
      end

      def body_type_matches_node_type
        return if node_type.blank? || body.blank?

        expected_body_class = body_class_for_node_type
        return if body.is_a?(expected_body_class)

        errors.add(:body, "must be a #{expected_body_class.name} for node_type=#{node_type}")
      end

      def body_class_for_node_type
        case node_type
        when USER_MESSAGE
          ::Messages::UserMessage
        when AGENT_MESSAGE
          ::Messages::AgentMessage
        when TASK
          ::Messages::ToolCall
        when SUMMARY
          ::Messages::Summary
        else
          DAG::NodeBody
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
