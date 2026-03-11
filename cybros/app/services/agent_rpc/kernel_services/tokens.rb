module AgentRPC
  module KernelServices
    class Tokens
      MessageEnvelope = Data.define(:content)

      def self.estimate_text(draft:, text:)
        new(draft: draft).estimate_text(text: text)
      end

      def self.estimate_messages(draft:, messages:)
        new(draft: draft).estimate_messages(messages: messages)
      end

      def initialize(draft:)
        @draft = draft
      end

      def estimate_text(text:)
        { "estimated_tokens" => token_counter.count_text(text.to_s) }
      end

      def estimate_messages(messages:)
        normalized_messages =
          Array(messages).map do |message|
            MessageEnvelope.new(content: normalize_message_content(message))
          end

        { "estimated_tokens" => token_counter.count_messages(normalized_messages) }
      end

      private

        attr_reader :draft

        def token_counter
          @token_counter ||= Cybros::AgentRuntimeResolver.token_counter_for_model_ref(model_ref: resolved_model_ref)
        end

        def resolved_model_ref
          draft.selected_model_ref.to_s.presence ||
            Cybros::AgentRuntimeResolver.model_resolution_for(conversation: draft.bound_conversation).fetch(:model_ref)
        end

        def normalize_message_content(message)
          content =
            if message.respond_to?(:content)
              message.content
            elsif message.is_a?(Hash)
              message.fetch("content", message.fetch(:content, nil))
            else
              message
            end

          case content
          when Array
            content.map { |block| normalize_content_block(block) }
          else
            content.to_s
          end
        end

        def normalize_content_block(block)
          return block if block.is_a?(AgentCore::TextContent) ||
            block.is_a?(AgentCore::ImageContent) ||
            block.is_a?(AgentCore::DocumentContent) ||
            block.is_a?(AgentCore::AudioContent)

          unless block.is_a?(Hash)
            return AgentCore::TextContent.new(text: block.to_s)
          end

          type = block.fetch("type", block.fetch(:type, "text")).to_s

          case type
          when "text"
            AgentCore::TextContent.new(text: block.fetch("text", block.fetch(:text, "")))
          when "image"
            AgentCore::ImageContent.from_h(block)
          when "document"
            AgentCore::DocumentContent.from_h(block)
          when "audio"
            AgentCore::AudioContent.from_h(block)
          else
            AgentCore::TextContent.new(text: block.to_s)
          end
        end
    end
  end
end
