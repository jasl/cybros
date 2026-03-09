require "json"

module AgentCore
  module Resources
    module Provider
      # Optional Provider implementation built on SimpleInference (OpenAI-compatible).
      #
      # This is a soft dependency and is only loaded/required when used.
      #
      # @example
      #   require "agent_core"
      #   require "agent_core/resources/provider/simple_inference_provider"
      #
      #   provider = AgentCore::Resources::Provider::SimpleInferenceProvider.new(
      #     base_url: "https://api.openai.com",
      #     api_key: ENV["OPENAI_API_KEY"],
      #   )
      class SimpleInferenceProvider < Base
        def initialize(
          client: nil,
          wire_api: :chat_completions,
          responses_path: nil,
          transport: nil,
          stream_include_usage: true,
          request_defaults: {},
          **client_options
        )
          @client = client
          @client_options = client_options
          @wire_api = wire_api&.to_sym
          @responses_path = responses_path
          @transport = transport
          @stream_include_usage = stream_include_usage == true
          @request_defaults = normalize_request_defaults(request_defaults)
          @last_call_metadata = {}
          @provider_request_sequences = Hash.new(0)
          @provider_request_sequences_mutex = Mutex.new
        end

        def name = "simple_inference"

        def last_call_metadata
          @last_call_metadata || {}
        end

        def chat(messages:, model:, tools: nil, stream: false, **options)
          @last_call_metadata = {}

          model_name = model.to_s.strip
          ValidationError.raise!(
            "model is required",
            code: "agent_core.resources.provider.simple_inference_provider.model_is_required",
          ) if model_name.empty?

          runtime_governance = extract_runtime_governance(options)
          client = ensure_client!

          with_provider_budget_reservation(runtime_governance: runtime_governance) do
            case @wire_api
            when :chat_completions
              request_messages = build_openai_messages(messages)
              request_tools = tools.nil? || tools.empty? ? nil : build_openai_tools(tools)

              request = { model: model_name, messages: request_messages }
              request[:tools] = request_tools if request_tools

              request_options = @request_defaults.merge(sanitize_options(options))

              if request_tools && !request_options.key?(:parallel_tool_calls)
                request_options[:parallel_tool_calls] = false
              end

              if stream
                stream_chat(client: client, request: request, options: request_options)
              else
                sync_chat(client: client, request: request, options: request_options)
              end
            when :responses
              request_tools = tools.nil? || tools.empty? ? nil : build_responses_tools(tools)

              transport = normalize_transport(@transport)
              if transport == :websocket
                ValidationError.raise!(
                  "websocket transport is not supported yet for wire_api=responses",
                  code: "agent_core.resources.provider.simple_inference_provider.responses_websocket_transport_not_supported_yet",
                )
              end
              if transport == :auto
                @last_call_metadata =
                  @last_call_metadata.merge(
                    "llm_transport" => {
                      "configured" => "auto",
                      "effective" => "http_sse",
                      "fallback" => "websocket_not_supported",
                    },
                  )
              end

              request_options = @request_defaults.merge(sanitize_options(options))
              request_options = normalize_responses_request_options(request_options)
              instructions, response_messages = extract_responses_instructions(messages)
              explicit_instructions = request_options.delete(:instructions).to_s
              combined_instructions = [instructions, explicit_instructions].filter_map { |value| value.presence }.join("\n\n")
              request_options[:store] = false unless request_options.key?(:store)

              request_messages = build_responses_input(response_messages)
              request = { model: model_name, input: request_messages }
              request[:instructions] = combined_instructions if combined_instructions.present?
              request[:tools] = request_tools if request_tools

              if request_tools && !request_options.key?(:parallel_tool_calls)
                request_options[:parallel_tool_calls] = false
              end

              if stream
                stream_responses(client: client, request: request, options: request_options)
              else
                sync_responses(client: client, request: request, options: request_options)
              end
            else
              ValidationError.raise!(
                "wire_api must be :chat_completions or :responses",
                code: "agent_core.resources.provider.simple_inference_provider.wire_api_must_be_chat_completions_or_responses",
                details: { wire_api: @wire_api.to_s },
              )
            end
          end
        end

        private

        def ensure_client!
          return @client if @client

          require_simple_inference!
          if @wire_api == :responses
            @client =
              ::SimpleInference::Protocols::OpenAIResponses.new(
                **@client_options,
                responses_path: @responses_path,
              )
          else
            @client = ::SimpleInference::Client.new(**@client_options)
          end
        end

        def require_simple_inference!
          return if defined?(::SimpleInference::Client)

          require "simple_inference"
        rescue LoadError => e
          raise LoadError,
                "The 'simple_inference' gem is required for AgentCore::Resources::Provider::SimpleInferenceProvider. " \
                "Add `gem \"simple_inference\"` to your Gemfile.",
                cause: e
        end

        def sanitize_options(options)
          out = Utils.symbolize_keys(options)
          out.delete(:stream)
          out.delete(:runtime_governance)
          out
        end

        def extract_runtime_governance(options)
          value = options.is_a?(Hash) ? options[:runtime_governance] || options["runtime_governance"] : nil
          value.is_a?(Hash) ? Utils.deep_symbolize_keys(value) : nil
        end

        def with_provider_budget_reservation(runtime_governance:)
          context = normalize_provider_budget_context(runtime_governance)
          return yield if context.nil?

          provider_credential = context.fetch(:provider_credential)
          provider_request_id = context.fetch(:provider_request_id)

          @last_call_metadata =
            @last_call_metadata.merge(
              "runtime_governance" => {
                "provider_credential_id" => provider_credential.id,
                "provider_key" => provider_credential.provider_key,
                "provider_request_id" => provider_request_id,
              },
            )

          acquisition =
            RuntimeGovernance::ProviderBudgetReservations.acquire!(
              provider_credential: provider_credential,
              provider_request_id: provider_request_id,
              request_units: context.fetch(:request_units),
              estimated_tokens: context.fetch(:estimated_tokens),
              owner_type: context.fetch(:owner_type),
              owner_id: context.fetch(:owner_id),
            )

          if acquisition.fetch(:decision) == "parked"
            runtime_wait = acquisition.fetch(:runtime_wait)
            publish_provider_limit_event(
              instrumenter: context[:instrumenter],
              provider_credential: provider_credential,
              provider_request_id: provider_request_id,
              runtime_wait: runtime_wait,
            )

            raise AgentCore::RuntimeWaitError.new(
              "Provider admission blocked",
              reason_type: runtime_wait.reason_type,
              retry_at: runtime_wait.retry_at,
              runtime_wait_id: runtime_wait.id,
              details: runtime_wait.details,
            )
          end

          response = yield

          if response.is_a?(Enumerator)
            wrap_stream_with_provider_budget_reservation(
              enum: response,
              provider_credential: provider_credential,
              provider_request_id: provider_request_id,
            )
          else
            settle_provider_budget_reservation(
              provider_credential: provider_credential,
              provider_request_id: provider_request_id,
              usage: response.respond_to?(:usage) ? response.usage : nil,
            )
            response
          end
        rescue StandardError
          release_provider_budget_reservation(
            provider_credential: provider_credential,
            provider_request_id: provider_request_id,
          ) if provider_credential && provider_request_id
          raise
        end

        def normalize_provider_budget_context(runtime_governance)
          raw = runtime_governance.is_a?(Hash) ? runtime_governance : {}
          provider_credential_id = raw[:provider_credential_id]
          provider_key = raw[:provider_key].to_s.strip

          provider_credential =
            if provider_credential_id.present?
              LLMProviderCredential.find_by(id: provider_credential_id, status: "active")
            elsif provider_key.present?
              LLMProviderCredential.find_by(provider_key: provider_key, status: "active")
            end

          return nil unless provider_credential

          namespace = raw[:request_namespace].to_s.strip
          namespace = provider_credential.provider_key if namespace.empty?

          owner_type = raw[:owner_type].to_s.strip
          owner_id = raw[:owner_id].to_s.strip
          owner_type = "ProviderCall" if owner_type.empty?
          owner_id = next_provider_request_id(namespace) if owner_id.empty?

          {
            provider_credential: provider_credential,
            provider_request_id: raw[:provider_request_id].to_s.strip.presence || next_provider_request_id(namespace),
            owner_type: owner_type,
            owner_id: owner_id,
            request_units: positive_integer_or_default(raw[:request_units], 1),
            estimated_tokens: non_negative_integer_or_default(raw[:estimated_tokens], 0),
            instrumenter: raw[:instrumenter],
          }
        end

        def next_provider_request_id(namespace)
          @provider_request_sequences_mutex.synchronize do
            @provider_request_sequences[namespace] += 1
            "#{namespace}:#{@provider_request_sequences[namespace]}"
          end
        end

        def positive_integer_or_default(value, default)
          integer = Integer(value, exception: false)
          integer && integer.positive? ? integer : default
        end

        def non_negative_integer_or_default(value, default)
          integer = Integer(value, exception: false)
          integer && integer >= 0 ? integer : default
        end

        def publish_provider_limit_event(instrumenter:, provider_credential:, provider_request_id:, runtime_wait:)
          return unless instrumenter.respond_to?(:publish)

          instrumenter.publish(
            "agent_core.llm.rate_limit",
            {
              provider_credential_id: provider_credential.id,
              provider_key: provider_credential.provider_key,
              provider_request_id: provider_request_id,
              reason_type: runtime_wait.reason_type,
              runtime_wait_id: runtime_wait.id,
              retry_at: runtime_wait.retry_at,
            },
          )
        end

        def wrap_stream_with_provider_budget_reservation(enum:, provider_credential:, provider_request_id:)
          Enumerator.new do |y|
            finalized = false

            enum.each do |event|
              case event
              when StreamEvent::Done
                settle_provider_budget_reservation(
                  provider_credential: provider_credential,
                  provider_request_id: provider_request_id,
                  usage: event.usage,
                )
                finalized = true
              when StreamEvent::ErrorEvent
                release_provider_budget_reservation(
                  provider_credential: provider_credential,
                  provider_request_id: provider_request_id,
                )
                finalized = true
              end

              y << event
            end
          rescue StandardError
            release_provider_budget_reservation(
              provider_credential: provider_credential,
              provider_request_id: provider_request_id,
            )
            raise
          ensure
            unless finalized
              release_provider_budget_reservation(
                provider_credential: provider_credential,
                provider_request_id: provider_request_id,
              )
            end
          end
        end

        def settle_provider_budget_reservation(provider_credential:, provider_request_id:, usage:)
          RuntimeGovernance::ProviderBudgetReservations.settle!(
            provider_credential: provider_credential,
            provider_request_id: provider_request_id,
            actual_tokens: total_tokens_for(usage),
          )
        rescue ActiveRecord::RecordNotFound
          nil
        end

        def release_provider_budget_reservation(provider_credential:, provider_request_id:)
          RuntimeGovernance::ProviderBudgetReservations.release!(
            provider_credential: provider_credential,
            provider_request_id: provider_request_id,
          )
        rescue ActiveRecord::RecordNotFound
          nil
        end

        def total_tokens_for(usage)
          return 0 if usage.nil?

          if usage.respond_to?(:total_tokens)
            Integer(usage.total_tokens, exception: false) || 0
          elsif usage.is_a?(Hash)
            Integer(usage[:total_tokens] || usage["total_tokens"], exception: false) || 0
          else
            0
          end
        end

        def normalize_transport(value)
          s = value.to_s.strip.downcase
          return nil if s.empty?

          case s
          when "http", "http_sse", "sse"
            :http_sse
          when "websocket", "ws"
            :websocket
          when "auto"
            :auto
          else
            nil
          end
        end

        def normalize_request_defaults(value)
          return {} if value.nil?
          ValidationError.raise!(
            "request_defaults must be a Hash",
            code: "agent_core.resources.provider.simple_inference_provider.request_defaults_must_be_a_hash",
            details: { value_class: value.class.name },
          ) unless value.is_a?(Hash)

          Utils.deep_symbolize_keys(value)
        end

        def sync_chat(client:, request:, options:)
          require_simple_inference!

          response = client.chat_completions(**request.merge(options))
          body = response.body.is_a?(Hash) ? response.body : {}

          message, stop_reason = message_from_openai_body(body)
          usage = usage_from_openai_body(body)

          Resources::Provider::Response.new(
            message: message,
            usage: usage,
            raw: body,
            stop_reason: stop_reason
          )
        rescue ::SimpleInference::HTTPError => e
          raise ProviderError.new(e.message, status: e.status, body: e.body)
        rescue ::SimpleInference::ValidationError => e
          raise simple_inference_validation_error(e)
        rescue ::SimpleInference::Error => e
          raise ProviderError, e.message
        end

        def sync_responses(client:, request:, options:)
          require_simple_inference!
          validate_responses_client_method!(client, :responses)

          result = client.responses(**request.merge(options))
          text = result.output_text.to_s
          usage_obj = usage_from_responses_usage(result.usage)
          tool_calls = tool_calls_from_responses_output_items(result.respond_to?(:output_items) ? result.output_items : nil)
          response_body = result.response.respond_to?(:body) ? result.response.body : nil
          stop_reason = stop_reason_from_responses_payload(response_body, tool_calls: tool_calls)

          Resources::Provider::Response.new(
            message: Message.new(role: :assistant, content: text, tool_calls: tool_calls.empty? ? nil : tool_calls),
            usage: usage_obj,
            raw: response_body || {},
            stop_reason: stop_reason
          )
        rescue ::SimpleInference::HTTPError => e
          raise ProviderError.new(e.message, status: e.status, body: e.body)
        rescue ::SimpleInference::ValidationError => e
          raise simple_inference_validation_error(e)
        rescue ::SimpleInference::Error => e
          raise ProviderError, e.message
        end

        def stream_chat(client:, request:, options:)
          require_simple_inference!

          stream_options = options.fetch(:stream_options, nil)
          stream_options = Utils.deep_symbolize_keys(stream_options) if stream_options.is_a?(Hash)

          if @stream_include_usage && (stream_options.nil? || stream_options.is_a?(Hash))
            stream_options ||= {}
            stream_options[:include_usage] = true unless stream_options.key?(:include_usage)
          end

          stream_request = request.merge(options)
          stream_request[:stream_options] = stream_options if stream_options

          Enumerator.new do |y|
            content = +""
            finish_reason = nil
            last_usage = nil

            tool_states = {}
            tool_started = {}
            used_tool_call_ids = {}

            client.chat_completions_stream(**stream_request) do |event|
              delta = ::SimpleInference::OpenAI.chat_completion_chunk_delta(event)
              if delta
                content << delta
                y << StreamEvent::TextDelta.new(text: delta)
              end

              choice0 = event.is_a?(Hash) ? event.dig("choices", 0) : nil
              fr = choice0.is_a?(Hash) ? choice0["finish_reason"] : nil
              finish_reason = fr if fr

              usage = event.is_a?(Hash) ? event["usage"] : nil
              last_usage = usage if usage.is_a?(Hash)

              delta_hash = choice0.is_a?(Hash) ? choice0["delta"] : nil
              tool_deltas = delta_hash.is_a?(Hash) ? delta_hash["tool_calls"] : nil

              each_tool_call_delta(tool_deltas) do |idx, id, name, arguments_delta|
                state = tool_states[idx] ||= { id: nil, name: nil, arguments: +"" }
                state[:id] ||=
                  Utils.normalize_tool_call_id(
                    id,
                    used: used_tool_call_ids,
                    fallback: "tc_#{idx + 1}",
                  )
                state[:name] ||= name if name

                if state[:id] && state[:name] && !tool_started[state[:id]]
                  tool_started[state[:id]] = true
                  y << StreamEvent::ToolCallStart.new(id: state[:id], name: state[:name])
                end

                if arguments_delta
                  state[:arguments] << arguments_delta
                  y << StreamEvent::ToolCallDelta.new(id: state[:id], arguments_delta: arguments_delta) if state[:id]
                end
              end
            end

            tool_calls = build_tool_calls_from_states(tool_states)
            tool_calls.each do |tc|
              y << StreamEvent::ToolCallEnd.new(id: tc.id, name: tc.name, arguments: tc.arguments)
            end

            message = Message.new(role: :assistant, content: content, tool_calls: tool_calls.empty? ? nil : tool_calls)
            stop_reason = stop_reason_from_finish_reason(finish_reason)
            usage_obj = usage_from_openai_usage(last_usage)

            y << StreamEvent::MessageComplete.new(message: message)
            y << StreamEvent::Done.new(stop_reason: stop_reason, usage: usage_obj)
          rescue ::SimpleInference::Error => e
            y << StreamEvent::ErrorEvent.new(error: normalize_stream_error(e), recoverable: stream_error_recoverable?(e))
          rescue StandardError => e
            y << StreamEvent::ErrorEvent.new(error: normalize_stream_error(e), recoverable: stream_error_recoverable?(e))
          end
        end

        def stream_responses(client:, request:, options:)
          require_simple_inference!
          validate_responses_client_method!(client, :responses_stream)

          Enumerator.new do |y|
            content = +""
            last_usage = nil
            tool_states = {}
            tool_started = {}
            raw_stream_response = nil
            completed_response = nil

            raw_stream_response =
              client.responses_stream(**request.merge(options)) do |event|
              delta =
                if event.is_a?(Hash) && event["type"].to_s == "response.output_text.delta"
                  event["delta"].to_s
                end
              if delta && !delta.empty?
                content << delta
                y << StreamEvent::TextDelta.new(text: delta)
              end

              if event.is_a?(Hash)
                case event["type"].to_s
                when "response.output_item.added"
                  item = event.fetch("item", nil)
                  if item.is_a?(Hash) && item["type"].to_s == "function_call"
                    item_id = item["id"].to_s.strip
                    call_id = item["call_id"].to_s.strip
                    stable_id = call_id.present? ? call_id : item_id
                    name = item["name"].to_s.strip
                    next if item_id.empty? || stable_id.empty?

                    state = tool_states[item_id] ||= { id: nil, name: nil, arguments: +"", output_index: nil, sequence_number: nil, pending_deltas: [], id_stable: false }
                    if state[:id].to_s == item_id && call_id.present?
                      state[:id] = call_id
                    else
                      state[:id] ||= stable_id
                    end
                    state[:id_stable] = true
                    state[:name] ||= name if name.present?
                    state[:output_index] ||= Integer(event["output_index"], exception: false)
                    state[:sequence_number] ||= Integer(event["sequence_number"], exception: false)

                    emit_tool_call_start_if_ready!(y, state, tool_started)
                    flush_pending_tool_call_deltas!(y, state, tool_started)
                  end
                when "response.function_call_arguments.delta"
                  item_id = event["item_id"].to_s.strip
                  delta_args = event["delta"].to_s
                  next if item_id.empty? || delta_args.empty?

                  state = tool_states[item_id] ||= { id: nil, name: nil, arguments: +"", output_index: nil, sequence_number: nil, pending_deltas: [], id_stable: false }
                  state[:id] ||= item_id
                  state[:output_index] ||= Integer(event["output_index"], exception: false)
                  state[:sequence_number] ||= Integer(event["sequence_number"], exception: false)
                  state[:arguments] << delta_args
                  if tool_call_live_events_ready?(state) && tool_started[state[:id]]
                    y << StreamEvent::ToolCallDelta.new(id: state[:id], arguments_delta: delta_args)
                  else
                    state[:pending_deltas] << delta_args
                  end
                when "response.function_call_arguments.done"
                  item_id = event["item_id"].to_s.strip
                  next if item_id.empty?

                  state = tool_states[item_id] ||= { id: nil, name: nil, arguments: +"", output_index: nil, sequence_number: nil, pending_deltas: [], id_stable: false }
                  state[:id] ||= item_id
                  state[:output_index] ||= Integer(event["output_index"], exception: false)
                  state[:sequence_number] ||= Integer(event["sequence_number"], exception: false)
                  name = event["name"].to_s.strip
                  state[:name] ||= name if name.present?

                  args = event["arguments"].to_s
                  state[:arguments] = args if !args.empty?
                  emit_tool_call_start_if_ready!(y, state, tool_started)
                  flush_pending_tool_call_deltas!(y, state, tool_started)
                when "response.completed"
                  response = event["response"]
                  completed_response = response if response.is_a?(Hash)
                end
              end

              if event.is_a?(Hash) && event["type"].to_s == "response.completed"
                usage = event.dig("response", "usage") || event["usage"]
                last_usage = usage if usage.is_a?(Hash)
              end
            end

            response_body = raw_stream_response.respond_to?(:body) && raw_stream_response.body.is_a?(Hash) ? raw_stream_response.body : nil
            raw_output_items = response_body ? responses_output_items_from_body(response_body) : []
            content = responses_output_text_from_body(response_body) if content.empty? && response_body
            last_usage ||= response_body["usage"] if response_body&.fetch("usage", nil).is_a?(Hash)

            tool_calls = build_tool_calls_from_item_states(tool_states)
            tool_calls = merge_streamed_tool_calls_with_response_body(tool_calls, raw_output_items) if raw_output_items.any?
            if tool_calls.empty? && raw_output_items.any?
              tool_calls = tool_calls_from_responses_output_items(raw_output_items)
            end
            tool_calls.each do |tc|
              y << StreamEvent::ToolCallEnd.new(id: tc.id, name: tc.name, arguments: tc.arguments)
            end

            message = Message.new(role: :assistant, content: content, tool_calls: tool_calls.empty? ? nil : tool_calls)
            usage_obj = usage_from_responses_usage(last_usage)
            stop_reason = stop_reason_from_responses_payload(response_body || completed_response, tool_calls: tool_calls)

            y << StreamEvent::MessageComplete.new(message: message)
            y << StreamEvent::Done.new(stop_reason: stop_reason, usage: usage_obj)
          rescue ::SimpleInference::Error => e
            y << StreamEvent::ErrorEvent.new(error: normalize_stream_error(e), recoverable: stream_error_recoverable?(e))
          rescue StandardError => e
            y << StreamEvent::ErrorEvent.new(error: normalize_stream_error(e), recoverable: stream_error_recoverable?(e))
          end
        end

        def usage_from_responses_usage(usage_hash)
          return nil unless usage_hash.is_a?(Hash)

          input_tokens = Integer(usage_hash.fetch("input_tokens", 0), exception: false) || 0
          output_tokens = Integer(usage_hash.fetch("output_tokens", 0), exception: false) || 0

          Resources::Provider::Usage.new(
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
          )
        end

        def tool_call_live_events_ready?(state)
          state[:id].to_s.present? && state[:name].to_s.present? && state[:id_stable] == true
        end

        def emit_tool_call_start_if_ready!(stream, state, tool_started)
          return unless tool_call_live_events_ready?(state)
          return if tool_started[state[:id]]

          tool_started[state[:id]] = true
          stream << StreamEvent::ToolCallStart.new(id: state[:id], name: state[:name])
        end

        def flush_pending_tool_call_deltas!(stream, state, tool_started)
          return unless tool_call_live_events_ready?(state)
          return unless tool_started[state[:id]]

          Array(state[:pending_deltas]).each do |delta|
            stream << StreamEvent::ToolCallDelta.new(id: state[:id], arguments_delta: delta)
          end
          state[:pending_deltas] = []
        end

        def responses_output_text_from_body(body)
          return "" unless body.is_a?(Hash)

          output = body["output"]
          return "" unless output.is_a?(Array)

          output.flat_map do |item|
            next [] unless item.is_a?(Hash)

            content = item["content"]
            next [] unless content.is_a?(Array)

            content.filter_map do |part|
              next nil unless part.is_a?(Hash)
              next nil unless part["type"].to_s == "output_text"

              part["text"].to_s
            end
          end.join
        end

        def responses_output_items_from_body(body)
          return [] unless body.is_a?(Hash)

          output = body["output"]
          return [] unless output.is_a?(Array)

          output.filter_map { |item| item.is_a?(Hash) ? item : nil }
        end

        def merge_streamed_tool_calls_with_response_body(tool_calls, raw_output_items)
          function_items =
            Array(raw_output_items).filter_map do |item|
              item.is_a?(Hash) && item["type"].to_s == "function_call" ? item : nil
            end

          return tool_calls if function_items.empty?

          tool_calls.map do |tool_call|
            raw_item =
              function_items.find do |item|
                item_id = item["id"].to_s.strip
                call_id = item["call_id"].to_s.strip
                args = item["arguments"].to_s
                matches_id = call_id == tool_call.id.to_s || item_id == tool_call.id.to_s
                matches_shape = item["name"].to_s == tool_call.name.to_s && args == JSON.generate(tool_call.arguments || {})
                matches_id || matches_shape
              end

            next tool_call unless raw_item

            merged_id = raw_item["call_id"].to_s.strip.presence || raw_item["id"].to_s.strip.presence || tool_call.id
            merged_name = raw_item["name"].to_s.strip.presence || tool_call.name
            raw_args = raw_item["arguments"]
            parsed_args, parse_error = Utils.parse_tool_arguments(raw_args)

            if parse_error
              AgentCore::ToolCall.new(
                id: merged_id,
                name: merged_name,
                arguments: tool_call.arguments,
                arguments_parse_error: tool_call.arguments_parse_error,
                arguments_raw: tool_call.arguments_raw,
              )
            else
              AgentCore::ToolCall.new(
                id: merged_id,
                name: merged_name,
                arguments: parsed_args,
              )
            end
          end
        end

        def normalize_stream_error(error)
          case error
          when ::SimpleInference::HTTPError
            ProviderError.new(error.message, status: error.status, body: error.body)
          when ::SimpleInference::ValidationError
            simple_inference_validation_error(error)
          else
            error
          end
        rescue StandardError
          error
        end

        def stream_error_recoverable?(error)
          case error
          when ::SimpleInference::TimeoutError,
               ::SimpleInference::ConnectionError,
               ::SimpleInference::DecodeError
            true
          else
            false
          end
        rescue StandardError
          false
        end

        def simple_inference_validation_error(error)
          ConfigurationError.new(
            error.message,
            code: "agent_core.resources.provider.simple_inference_provider.validation_error",
            details: { simple_inference_error_class: error.class.name },
          )
        end

        def message_from_openai_body(body)
          choice0 = body.dig("choices", 0)
          choice0 = {} unless choice0.is_a?(Hash)

          msg = choice0.fetch("message", nil)
          msg = {} unless msg.is_a?(Hash)

          content = ::SimpleInference::OpenAI.normalize_content(msg.fetch("content", nil)).to_s
          tool_calls = tool_calls_from_openai_message(msg)

          message = Message.new(role: :assistant, content: content, tool_calls: tool_calls.empty? ? nil : tool_calls)
          stop_reason = stop_reason_from_finish_reason(choice0.fetch("finish_reason", nil))

          [message, stop_reason]
        end

        def usage_from_openai_body(body)
          usage_hash = body.fetch("usage", nil)
          usage_from_openai_usage(usage_hash)
        end

        def usage_from_openai_usage(usage_hash)
          return nil unless usage_hash.is_a?(Hash)

          input_tokens = Integer(usage_hash.fetch("prompt_tokens", 0), exception: false) || 0
          output_tokens = Integer(usage_hash.fetch("completion_tokens", 0), exception: false) || 0

          details =
            begin
              d = usage_hash.fetch("prompt_tokens_details", nil)
              d.is_a?(Hash) ? d : {}
            rescue StandardError
              {}
            end

          cache_read_raw =
            details["cached_tokens"] ||
              details["cache_read_tokens"] ||
              details["cache_read_input_tokens"] ||
              usage_hash["cache_read_tokens"] ||
              usage_hash["cache_read_input_tokens"]

          cache_creation_raw =
            details["cache_creation_tokens"] ||
              details["cache_creation_input_tokens"] ||
              usage_hash["cache_creation_tokens"] ||
              usage_hash["cache_creation_input_tokens"]

          cache_read_tokens = Integer(cache_read_raw, exception: false) || 0
          cache_read_tokens = 0 if cache_read_tokens.negative?

          cache_creation_tokens = Integer(cache_creation_raw, exception: false) || 0
          cache_creation_tokens = 0 if cache_creation_tokens.negative?

          Resources::Provider::Usage.new(
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_creation_tokens: cache_creation_tokens,
            cache_read_tokens: cache_read_tokens,
          )
        end

        def stop_reason_from_finish_reason(value)
          case value.to_s
          when "tool_calls" then :tool_use
          when "function_call" then :tool_use
          when "length" then :max_tokens
          when "stop_sequence" then :stop_sequence
          else :end_turn
          end
        end

        def tool_calls_from_openai_message(msg)
          h = Utils.symbolize_keys(msg)

          tool_calls_raw = h.fetch(:tool_calls, nil)
          tool_calls =
            case tool_calls_raw
            when Array then tool_calls_raw
            when Hash then [tool_calls_raw]
            else []
            end

          parsed = []

          tool_calls.each do |tc_raw|
            next unless tc_raw.is_a?(Hash)

            tc = Utils.symbolize_keys(tc_raw)
            fn = Utils.symbolize_keys(tc.fetch(:function, nil))

            name = fn.fetch(:name, nil).to_s.strip
            next if name.empty?

            raw_args = fn.fetch(:arguments, nil)
            args_hash, parse_error = Utils.parse_tool_arguments(raw_args)
            raw = parse_error ? raw_args.to_s : nil

            parsed << {
              id: tc.fetch(:id, nil).to_s.strip,
              name: name,
              arguments: args_hash,
              arguments_parse_error: parse_error,
              arguments_raw: raw,
            }
          end

          if parsed.empty?
            fc_raw = h.fetch(:function_call, nil)
            if fc_raw.is_a?(Hash)
              fc = Utils.symbolize_keys(fc_raw)
              name = fc.fetch(:name, nil).to_s.strip
              unless name.empty?
                raw_args = fc.fetch(:arguments, nil)
                args_hash, parse_error = Utils.parse_tool_arguments(raw_args)
                raw = parse_error ? raw_args.to_s : nil
                parsed << { id: "", name: name, arguments: args_hash, arguments_parse_error: parse_error, arguments_raw: raw }
              end
            end
          end

          used = {}

          parsed.map.with_index do |data, idx|
            id =
              Utils.normalize_tool_call_id(
                data.fetch(:id),
                used: used,
                fallback: "tc_#{idx + 1}",
              )

            ToolCall.new(
              id: id,
              name: data.fetch(:name),
              arguments: data.fetch(:arguments),
              arguments_parse_error: data.fetch(:arguments_parse_error),
              arguments_raw: data.fetch(:arguments_raw, nil),
            )
          end
        end

        def build_openai_messages(messages)
          Array(messages).map do |msg|
            unless msg.is_a?(Message)
              ValidationError.raise!(
                "messages must contain AgentCore::Message instances",
                code: "agent_core.resources.provider.simple_inference_provider.messages_must_contain_agentcore_message_instances",
                details: { message_class: msg.class.name },
              )
            end

            role = openai_role(msg.role)

            out = { "role" => role }

            if role == "tool"
              call_id = msg.tool_call_id.to_s.strip
              ValidationError.raise!(
                "tool_result messages must include tool_call_id",
                code: "agent_core.resources.provider.simple_inference_provider.tool_result_requires_tool_call_id",
              ) if call_id.empty?

              out["tool_call_id"] = call_id
              out["content"] = msg.text.to_s
              next out
            end

            out["content"] = openai_content(msg)

            if role == "assistant" && msg.has_tool_calls?
              out["tool_calls"] = msg.tool_calls.map { |tc| openai_tool_call(tc) }
              if out["content"].is_a?(String) && out["content"].strip.empty?
                out["content"] = nil
              end
            end

            out
          end
        end

        def build_responses_input(messages)
          Array(messages).flat_map do |msg|
            unless msg.is_a?(Message)
              ValidationError.raise!(
                "messages must contain AgentCore::Message instances",
                code: "agent_core.resources.provider.simple_inference_provider.messages_must_contain_agentcore_message_instances",
                details: { message_class: msg.class.name },
              )
            end

            if msg.role == :tool_result
              call_id = msg.tool_call_id.to_s.strip
              ValidationError.raise!(
                "tool_result messages must include tool_call_id",
                code: "agent_core.resources.provider.simple_inference_provider.tool_result_requires_tool_call_id",
              ) if call_id.empty?

              [
                {
                  "type" => "function_call_output",
                  "call_id" => call_id,
                  "output" => msg.text.to_s,
                },
              ]
            else
              role = openai_role(msg.role)
              items = []
              items << { "role" => role, "content" => responses_content(msg) }

              if role == "assistant" && msg.has_tool_calls?
                msg.tool_calls.each do |tc|
                  args = tc.respond_to?(:arguments) ? (tc.arguments || {}) : {}
                  items << {
                    "type" => "function_call",
                    "call_id" => tc.id.to_s,
                    "name" => tc.name.to_s,
                    "arguments" => JSON.generate(args),
                  }
                end
              end

              items
            end
          end
        end

        def extract_responses_instructions(messages)
          instructions = []
          response_messages = []

          Array(messages).each do |msg|
            unless msg.is_a?(Message)
              ValidationError.raise!(
                "messages must contain AgentCore::Message instances",
                code: "agent_core.resources.provider.simple_inference_provider.messages_must_contain_agentcore_message_instances",
                details: { message_class: msg.class.name },
              )
            end

            if msg.role == :system
              text = responses_instruction_text(msg)
              instructions << text if text.present?
            else
              response_messages << msg
            end
          end

          [instructions.join("\n\n"), response_messages]
        end

        def normalize_responses_request_options(options)
          out = options.is_a?(Hash) ? options.dup : {}
          reasoning = out[:reasoning].is_a?(Hash) ? Utils.deep_symbolize_keys(out[:reasoning]) : {}

          if out.key?(:max_tokens)
            out[:max_output_tokens] = out[:max_tokens] unless out.key?(:max_output_tokens)
            out.delete(:max_tokens)
          end

          effort = out.delete(:reasoning_effort)
          summary = out.delete(:reasoning_summary)
          reasoning[:effort] = effort if effort.present?
          reasoning[:summary] = summary if summary.present?

          out[:reasoning] = reasoning if reasoning.any?
          out
        end

        def responses_instruction_text(msg)
          case msg.content
          when String
            msg.content.to_s.strip
          when Array
            msg.content.filter_map do |block|
              case block
              when TextContent
                block.text.to_s
              else
                block.respond_to?(:text) ? block.text.to_s : block.to_s
              end
            end.join.strip
          when nil
            ""
          else
            msg.content.to_s.strip
          end
        end

        def responses_content(msg)
          case msg.content
          when String
            [responses_text_part(role: msg.role, text: msg.content)]
          when Array
            msg.content.filter_map { |block| responses_part(block, role: msg.role) }
          when nil
            []
          else
            [responses_text_part(role: msg.role, text: msg.content.to_s)]
          end
        end

        def responses_part(block, role:)
          case block
          when TextContent
            responses_text_part(role: role, text: block.text.to_s)
          when ImageContent
            if role == :assistant
              responses_text_part(role: role, text: image_placeholder(block))
            else
              { "type" => "input_image", "image_url" => openai_image_url(block) }
            end
          when DocumentContent
            responses_text_part(role: role, text: document_placeholder(block))
          when AudioContent
            responses_text_part(role: role, text: audio_placeholder(block))
          when ToolUseContent, ToolResultContent
            responses_text_part(role: role, text: block.to_h.to_s)
          else
            responses_text_part(role: role, text: block.to_s)
          end
        end

        def responses_text_part(role:, text:)
          {
            "type" => role == :assistant ? "output_text" : "input_text",
            "text" => text.to_s,
          }
        end

        def validate_responses_client_method!(client, method_name)
          return if client.respond_to?(method_name)

          raise ConfigurationError.new(
                  "wire_api=responses client must implement the responses interface (missing ##{method_name})"
                )
        end

        def stop_reason_from_responses_payload(payload, tool_calls:)
          return :tool_use unless Array(tool_calls).empty?
          return :end_turn unless payload.is_a?(Hash)

          if payload["status"].to_s == "incomplete"
            case payload.dig("incomplete_details", "reason").to_s
            when "max_output_tokens" then :max_tokens
            else :end_turn
            end
          else
            :end_turn
          end
        end

        def openai_role(role)
          case role
          when :system then "system"
          when :user then "user"
          when :assistant then "assistant"
          when :tool_result then "tool"
          else
            ValidationError.raise!(
              "Unsupported message role: #{role.inspect}",
              code: "agent_core.resources.provider.simple_inference_provider.unsupported_message_role",
              details: { role: role.to_s, role_inspect: role.inspect },
            )
          end
        end

        def openai_content(msg)
          case msg.content
          when String
            msg.content
          when Array
            parts = msg.content.filter_map { |block| openai_part(block) }

            all_text = parts.all? { |p| p["type"] == "text" }
            return parts.map { |p| p["text"].to_s }.join if all_text

            parts
          when nil
            ""
          else
            msg.content.to_s
          end
        end

        def openai_part(block)
          case block
          when TextContent
            { "type" => "text", "text" => block.text.to_s }
          when ImageContent
            { "type" => "image_url", "image_url" => { "url" => openai_image_url(block) } }
          when DocumentContent
            { "type" => "text", "text" => document_placeholder(block) }
          when AudioContent
            { "type" => "text", "text" => audio_placeholder(block) }
          when ToolUseContent, ToolResultContent
            { "type" => "text", "text" => block.to_h.to_s }
          else
            { "type" => "text", "text" => block.to_s }
          end
        end

        def openai_image_url(block)
          case block.source_type
          when :url
            block.url.to_s
          when :base64
            mime = block.media_type.to_s
            data = block.data.to_s
            "data:#{mime};base64,#{data}"
          else
            ""
          end
        end

        def document_placeholder(block)
          mime = block.effective_media_type
          case block.source_type
          when :url
            "[document: #{mime || "unknown"} url=#{block.url}]"
          when :base64
            "[document: #{mime || "unknown"} base64]"
          else
            "[document]"
          end
        end

        def image_placeholder(block)
          mime = block.media_type.to_s.presence || "unknown"
          case block.source_type
          when :url
            "[image: #{mime} url=#{block.url}]"
          when :base64
            "[image: #{mime} base64]"
          else
            "[image]"
          end
        end

        def audio_placeholder(block)
          mime = block.effective_media_type
          transcript = block.respond_to?(:transcript) ? block.transcript.to_s : ""
          suffix = transcript.strip.empty? ? "" : " transcript=#{transcript.inspect}"

          case block.source_type
          when :url
            "[audio: #{mime || "unknown"} url=#{block.url}#{suffix}]"
          when :base64
            "[audio: #{mime || "unknown"} base64#{suffix}]"
          else
            "[audio#{suffix}]"
          end
        end

        def openai_tool_call(tc)
          args = tc.respond_to?(:arguments) ? (tc.arguments || {}) : {}

          {
            "id" => tc.id.to_s,
            "type" => "function",
            "function" => {
              "name" => tc.name.to_s,
              "arguments" => JSON.generate(args),
            },
          }
        end

        def build_openai_tools(tools)
          Array(tools).map do |tool|
            ValidationError.raise!(
              "tools must contain Hash definitions",
              code: "agent_core.resources.provider.simple_inference_provider.tools_must_contain_hash_definitions",
              details: { tool_class: tool.class.name },
            ) unless tool.is_a?(Hash)

            h = Utils.symbolize_keys(tool)

            name = ""
            description = ""
            parameters = {}

            if h[:type].to_s == "function" && h[:function].is_a?(Hash)
              fn = Utils.symbolize_keys(h.fetch(:function))
              name = fn.fetch(:name, "").to_s
              description = fn.fetch(:description, "").to_s
              parameters = fn.fetch(:parameters, {})
            else
              name = h.fetch(:name, "").to_s
              description = h.fetch(:description, "").to_s
              parameters = h.fetch(:parameters, {})
            end

            ValidationError.raise!(
              "tool name is required",
              code: "agent_core.resources.provider.simple_inference_provider.tool_name_is_required",
            ) if name.strip.empty?

            parameters = {} unless parameters.is_a?(Hash)
            parameters = Utils.normalize_json_schema(parameters)
            parameters = JSON.parse(JSON.generate(parameters))

            {
              "type" => "function",
              "function" => {
                "name" => name,
                "description" => description,
                "parameters" => parameters,
              },
            }
          end.compact
        end

        def build_responses_tools(tools)
          Array(tools).map do |tool|
            ValidationError.raise!(
              "tools must contain Hash definitions",
              code: "agent_core.resources.provider.simple_inference_provider.tools_must_contain_hash_definitions",
              details: { tool_class: tool.class.name },
            ) unless tool.is_a?(Hash)

            h = Utils.symbolize_keys(tool)

            name = ""
            description = ""
            parameters = {}

            if h[:type].to_s == "function" && h[:function].is_a?(Hash)
              fn = Utils.symbolize_keys(h.fetch(:function))
              name = fn.fetch(:name, "").to_s
              description = fn.fetch(:description, "").to_s
              parameters = fn.fetch(:parameters, {})
            else
              name = h.fetch(:name, "").to_s
              description = h.fetch(:description, "").to_s
              parameters = h.fetch(:parameters, {})
            end

            ValidationError.raise!(
              "tool name is required",
              code: "agent_core.resources.provider.simple_inference_provider.tool_name_is_required",
            ) if name.strip.empty?

            parameters = {} unless parameters.is_a?(Hash)
            parameters = Utils.normalize_json_schema(parameters)
            parameters = JSON.parse(JSON.generate(parameters))

            {
              "type" => "function",
              "name" => name,
              "description" => description,
              "strict" => false,
              "parameters" => parameters,
            }
          end.compact
        end

        def each_tool_call_delta(tool_deltas)
          Array(tool_deltas).each do |tc|
            next unless tc.is_a?(Hash)

            idx = Integer(tc.fetch("index", nil), exception: false)
            next if idx.nil? || idx < 0

            id = tc.fetch("id", nil)&.to_s
            fn = tc.fetch("function", nil)
            fn = {} unless fn.is_a?(Hash)

            name = fn.fetch("name", nil)&.to_s
            args_delta = fn.fetch("arguments", nil)

            yield idx, (id&.strip&.empty? ? nil : id), (name&.strip&.empty? ? nil : name), (args_delta.nil? ? nil : args_delta.to_s)
          end
        end

        def build_tool_calls_from_states(tool_states)
          tool_states
            .sort_by { |idx, _| idx }
            .filter_map do |idx, state|
              id = state.fetch(:id, nil).to_s.strip
              name = state.fetch(:name, nil).to_s.strip
              args = state.fetch(:arguments, "").to_s

              next if name.empty?

              id = "tc_#{idx + 1}" if id.empty?

              args_hash, parse_error = Utils.parse_tool_arguments(args)
              raw = parse_error ? args : nil
              ToolCall.new(id: id, name: name, arguments: args_hash, arguments_parse_error: parse_error, arguments_raw: raw)
            end
        end

        def tool_calls_from_responses_output_items(items)
          Array(items).filter_map do |item|
            next nil unless item.is_a?(Hash)
            next nil unless item["type"].to_s == "function_call"

            call_id = item["call_id"].to_s.strip
            item_id = item["id"].to_s.strip
            name = item["name"].to_s.strip
            args = item["arguments"]

            next nil if name.empty?

            id = call_id.present? ? call_id : item_id
            next nil if id.empty?

            args_hash, parse_error = Utils.parse_tool_arguments(args)
            raw = parse_error ? args.to_s : nil

            ToolCall.new(
              id: id,
              name: name,
              arguments: args_hash,
              arguments_parse_error: parse_error,
              arguments_raw: raw,
            )
          end
        end

        def build_tool_calls_from_item_states(tool_states)
          used = {}

          tool_states
            .to_a
            .sort_by do |item_id, state|
              [
                state.fetch(:output_index, nil) || Float::INFINITY,
                state.fetch(:sequence_number, nil) || Float::INFINITY,
                item_id.to_s,
              ]
            end
            .filter_map.with_index do |(_item_id, state), idx|
              id = state.fetch(:id, nil).to_s.strip
              name = state.fetch(:name, nil).to_s.strip
              args = state.fetch(:arguments, "").to_s

              next nil if name.empty?

              id =
                Utils.normalize_tool_call_id(
                  id,
                  used: used,
                  fallback: "tc_#{idx + 1}",
                )

              args_hash, parse_error = Utils.parse_tool_arguments(args)
              raw = parse_error ? args : nil

              ToolCall.new(id: id, name: name, arguments: args_hash, arguments_parse_error: parse_error, arguments_raw: raw)
            end
        end
      end
    end
  end
end
