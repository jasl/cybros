module Messages
  class AgentMessage < ::DAG::NodeBody
    class << self
      def turn_anchor?
        true
      end

      def transcript_candidate?
        true
      end

      def leaf_terminal?
        true
      end

      def default_leaf_repair?
        true
      end

      def executable?
        true
      end

      def transcript_include?(context_node_hash)
        state = context_node_hash["state"].to_s
        preview_content = context_node_hash.dig("payload", "output_preview", "content").to_s
        metadata = context_node_hash["metadata"].is_a?(Hash) ? context_node_hash["metadata"] : {}
        transcript_visible = metadata["transcript_visible"] == true
        terminal_reason = metadata["reason"].to_s.present?
        terminal_error = metadata["error"].to_s.present?

        state.in?([DAG::Node::PENDING, DAG::Node::RUNNING]) ||
          preview_content.present? ||
          transcript_visible ||
          (state.in?(DAG::Node::TERMINAL_STATES) && (terminal_reason || terminal_error))
      end

      def transcript_preview_override(context_node_hash)
        metadata = context_node_hash["metadata"].is_a?(Hash) ? context_node_hash["metadata"] : {}
        preview = metadata["transcript_preview"]
        if preview.is_a?(String) && preview.present?
          return preview.truncate(2000)
        end

        state = context_node_hash["state"].to_s
        error = metadata["error"].to_s
        reason = metadata["reason"].to_s

        case state
        when DAG::Node::ERRORED
          error_message = error.present? ? error : "errored"
          "Errored: #{error_message}".truncate(2000)
        when DAG::Node::REJECTED
          reason_message = reason.present? ? reason : "rejected"
          "Rejected: #{reason_message}".truncate(2000)
        when DAG::Node::CANCELLED
          if reason.present?
            "Cancelled: #{reason}".truncate(2000)
          else
            "Cancelled".truncate(2000)
          end
        when DAG::Node::SKIPPED
          if reason.present?
            "Skipped: #{reason.tr("_", " ")}".truncate(2000)
          else
            "Skipped".truncate(2000)
          end
        else
          nil
        end
      end
    end

      def retriable?
        true
      end

      def rerunnable?
        true
      end

    def preview_max_chars
      2000
    end
  end
end
