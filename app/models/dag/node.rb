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
    belongs_to :payload,
      class_name: "DAG::NodePayload",
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
      validate :payload_type_matches_node_type

      scope :active, -> { where(compressed_at: nil) }

    before_validation :ensure_payload

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
            self.payload.merge_output!(payload)
            self.payload.save!
          elsif !content.nil?
            self.payload.apply_finished_content!(content)
            self.payload.save!
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

        conversation.mutate! do |m|
          new_node = m.retry_replace!(node: self)
        end

        new_node
      end

      def regenerate!
        new_node = nil

        conversation.mutate! do |m|
          new_node = m.regenerate_replace!(node: self)
        end

        new_node
      end

      def edit!(new_input:)
        new_node = nil

        conversation.mutate! do |m|
          new_node = m.edit_replace!(node: self, new_input: new_input)
        end

        new_node
      end

      def fork!(node_type:, state:, payload_input: {}, payload_output: {}, metadata: {})
        new_node = nil

        conversation.mutate! do |m|
          new_node = m.fork_from!(
            from_node: self,
            node_type: node_type,
            state: state,
            payload_input: payload_input,
            payload_output: payload_output,
            metadata: metadata
          )
        end

        new_node
      end

      def payload_input
        if payload.input.is_a?(Hash)
          payload.input
        else
          {}
        end
      end

      def payload_input=(hash)
        ensure_payload

        if hash.is_a?(Hash)
          payload.input = hash.deep_stringify_keys
        else
          payload.input = {}
        end
      end

      def payload_output
        if payload.output.is_a?(Hash)
          payload.output
        else
          {}
        end
      end

      def payload_output=(hash)
        ensure_payload

        if hash.is_a?(Hash)
          payload.output = hash.deep_stringify_keys
        else
          payload.output = {}
        end
      end

      def payload_output_preview
        if payload.output_preview.is_a?(Hash)
          payload.output_preview
        else
          {}
        end
      end

      private

        def ensure_payload
          return if payload.present?
          return if node_type.blank?

          self.payload = payload_class_for_node_type.new
        end

        def payload_type_matches_node_type
          return if node_type.blank? || payload.blank?

          expected_payload_class = payload_class_for_node_type
          return if payload.is_a?(expected_payload_class)

          errors.add(:payload, "must be a #{expected_payload_class.name} for node_type=#{node_type}")
        end

        def payload_class_for_node_type
          case node_type
          when USER_MESSAGE
            DAG::NodePayloads::UserMessage
          when AGENT_MESSAGE
          DAG::NodePayloads::AgentMessage
          when TASK
          DAG::NodePayloads::ToolCall
          when SUMMARY
          DAG::NodePayloads::Summary
          else
          DAG::NodePayload
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
