module AgentCore
  module Resources
    module Memory
      module Embedder
        class SimpleInference
          def initialize(client: nil, model:, **client_options)
            @client = client
            @client_options = client_options
            @model = model.to_s.strip

            ValidationError.raise!(
              "model is required",
              code: "agent_core.memory.embedder.simple_inference.model_is_required",
            ) if @model.empty?
          end

          def embed(text:)
            input = text.to_s
            ValidationError.raise!(
              "text is required",
              code: "agent_core.memory.embedder.simple_inference.text_is_required",
            ) if input.strip.empty?

            client = ensure_client!

            response = client.embeddings(model: @model, input: input)
            body = response.body.is_a?(Hash) ? response.body : {}

            data0 = Array(body.fetch("data", nil)).first
            embedding = data0.is_a?(Hash) ? data0.fetch("embedding", nil) : nil

            unless embedding.is_a?(Array) && embedding.all? { |v| v.is_a?(Numeric) }
              raise AgentCore::ProviderError, "invalid embeddings response"
            end

            embedding.map(&:to_f)
          rescue ::SimpleInference::Errors::HTTPError => e
            raise AgentCore::ProviderError.new(e.message, status: e.status, body: e.body)
          rescue ::SimpleInference::Errors::Error => e
            raise AgentCore::ProviderError, e.message
          end

          private

            def ensure_client!
              return @client if @client

              require_simple_inference!
              @client = ::SimpleInference::Client.new(**@client_options)
            end

            def require_simple_inference!
              return if defined?(::SimpleInference::Client)

              require "simple_inference"
            rescue LoadError => e
              raise LoadError,
                    "The 'simple_inference' gem is required for AgentCore::Resources::Memory::Embedder::SimpleInference. " \
                    "Add `gem \"simple_inference\"` to your Gemfile.",
                    cause: e
            end
        end
      end
    end
  end
end
