module Cybros
  module LLM
    class CapabilityGatedProvider
      def initialize(delegate:, provider_key:, model_ref:, api_model:, supports_tools:, supports_images:)
        @delegate = delegate
        @provider_key = provider_key.to_s
        @model_ref = model_ref.to_s
        @api_model = api_model.to_s
        @supports_tools = supports_tools == true
        @supports_images = supports_images == true
      end

      def name
        @provider_key
      end

      attr_reader :provider_key, :model_ref, :api_model

      def last_call_metadata
        @delegate.respond_to?(:last_call_metadata) ? @delegate.last_call_metadata : {}
      rescue StandardError
        {}
      end

      def chat(messages:, model:, tools: nil, stream: false, **options)
        if tools && !Array(tools).empty? && !@supports_tools
          AgentCore::ValidationError.raise!(
            "Selected model does not support tool calling",
            code: "cybros.llm.capabilities.tools_not_supported",
            details: { provider_key: @provider_key, model_ref: @model_ref, api_model: @api_model },
          )
        end

        if contains_image?(messages) && !@supports_images
          AgentCore::ValidationError.raise!(
            "Selected model does not support image input",
            code: "cybros.llm.capabilities.image_input_not_supported",
            details: { provider_key: @provider_key, model_ref: @model_ref, api_model: @api_model },
          )
        end

        @delegate.chat(messages: messages, model: model, tools: tools, stream: stream, **options)
      end

      private

      def contains_image?(messages)
        Array(messages).any? do |msg|
          content = msg.respond_to?(:content) ? msg.content : nil
          next false unless content.is_a?(Array)

          content.any? do |block|
            block.is_a?(AgentCore::ImageContent) ||
              (block.respond_to?(:type) && block.type.to_sym == :image)
          rescue StandardError
            false
          end
        end
      rescue StandardError
        false
      end
    end
  end
end
