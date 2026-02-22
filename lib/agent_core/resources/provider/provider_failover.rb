# frozen_string_literal: true

module AgentCore
  module Resources
    module Provider
      class ProviderFailover
        FAILOVER_MESSAGE_KEYWORDS = %w[
          tools
          tool
          function
          tool_choice
          response_format
          json_schema
          schema
          parallel_tool_calls
          unsupported model
          model not found
        ].freeze

        def self.call(provider:, requested_model:, fallback_models:, messages:, tools:, stream:, options:, instrumenter:, run_id:)
          new(
            provider: provider,
            requested_model: requested_model,
            fallback_models: fallback_models,
            messages: messages,
            tools: tools,
            stream: stream,
            options: options,
            instrumenter: instrumenter,
            run_id: run_id,
          ).call
        end

        def initialize(provider:, requested_model:, fallback_models:, messages:, tools:, stream:, options:, instrumenter:, run_id:)
          @provider = provider
          @requested_model = requested_model.to_s
          @fallback_models = Array(fallback_models)
          @messages = Array(messages)
          @tools = tools
          @stream = stream == true
          @options = options.is_a?(Hash) ? options : {}
          @instrumenter = instrumenter
          @run_id = run_id.to_s
        end

        def call
          models = normalize_models(@requested_model, @fallback_models)

          attempts = []
          last_error = nil

          models.each do |model|
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            response =
              @provider.chat(
                messages: @messages,
                model: model,
                tools: @tools,
                stream: @stream,
                **@options
              )

            elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
            attempts << { "model" => model, "ok" => true, "elapsed_ms" => elapsed_ms }

            publish_failover_event(attempts: attempts, used_model: model)

            return { response: response, used_model: model, attempts: attempts }
          rescue AgentCore::ProviderError => e
            elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0

            attempts << {
              "model" => model,
              "ok" => false,
              "status" => e.status,
              "error_class" => e.class.name,
              "error_message" => e.message.to_s,
              "elapsed_ms" => elapsed_ms,
            }.compact

            last_error = e

            next if failover_error?(e) && model != models.last

            raise e
          end

          raise last_error if last_error

          raise ValidationError, "No models provided for provider failover"
        end

        private

        def publish_failover_event(attempts:, used_model:)
          return if attempts.length <= 1 && used_model.to_s == @requested_model.to_s

          payload = {
            run_id: @run_id,
            requested_model: @requested_model.to_s,
            used_model: used_model.to_s,
            attempts: attempts,
          }.compact

          @instrumenter.publish("agent_core.llm.failover", payload) if @instrumenter.respond_to?(:publish)
        rescue StandardError
          nil
        end

        def normalize_models(requested_model, fallback_models)
          list = [requested_model.to_s, *Array(fallback_models).map(&:to_s)]
          list = list.map { |m| m.to_s.strip }.reject(&:empty?)

          seen = {}
          list.each_with_object([]) do |m, out|
            next if seen[m]

            seen[m] = true
            out << m
          end
        end

        def failover_error?(error)
          status = error.status
          return true if status == 404

          return false unless status == 400 || status == 422

          haystack = build_error_haystack(error)
          return false if haystack.empty?

          FAILOVER_MESSAGE_KEYWORDS.any? { |kw| haystack.include?(kw) }
        rescue StandardError
          false
        end

        def build_error_haystack(error)
          parts = []
          parts << error.message.to_s
          parts << error.body.to_s unless error.body.nil?
          parts.join("\n").downcase
        end
      end
    end
  end
end
