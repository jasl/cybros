# frozen_string_literal: true

require "json"
require "uri"
require "timeout"
require "socket"

require_relative "base"

module SimpleInference
  module Protocols
    # OpenAI Responses API protocol implementation.
    #
    # This protocol targets `POST /v1/responses` (or other configured path),
    # including SSE streaming (`text/event-stream`).
    class OpenAIResponses < Base
      ResponsesResult =
        Struct.new(
          :output_text,
          :output_items,
          :usage,
          :response,
          keyword_init: true
        )

      def initialize(options = {})
        super
        opts = options.is_a?(Hash) ? options : {}
        @responses_path = opts[:responses_path] || opts["responses_path"] || "/v1/responses"
        @responses_path = @responses_path.to_s.strip
        @responses_path = "/v1/responses" if @responses_path.empty?
        @responses_path = "/#{@responses_path}" unless @responses_path.start_with?("/")
      end

      # POST /responses (non-streaming)
      def responses_create(**params)
        post_json(@responses_path, params)
      end

      # POST /responses (streaming)
      #
      # Yields parsed JSON events from an OpenAI-style SSE stream (`text/event-stream`).
      #
      # If no block is given, returns an Enumerator.
      def responses_stream(**params)
        return enum_for(:responses_stream, **params) unless block_given?

        body = params.dup
        body.delete(:stream)
        body.delete("stream")
        body["stream"] = true

        post_json_stream(@responses_path, body) do |event|
          yield event
        end
      end

      # High-level helper for Responses API.
      #
      # - Non-streaming: returns ResponsesResult with `output_text` + `usage`.
      # - Streaming: yields `output_text` deltas to the block (if given), accumulates, and returns ResponsesResult.
      #
      # @yield [String] output_text delta chunks (streaming only)
      def responses(model:, input:, stream: nil, include_usage: true, **params, &block)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?

        use_stream = stream.nil? ? block_given? : stream

        request = { model: model, input: input }.merge(params)
        request.delete(:stream)
        request.delete("stream")

        if use_stream
          full = +""
          last_usage = nil
          output_item_states = {}
          output_item_order = []

          response =
            responses_stream(**request) do |event|
              delta = output_text_delta(event)
              if delta
                full << delta
                block.call(delta) if block
              end

              usage = usage_from_event(event)
              last_usage = usage if usage

              collect_output_item_event!(event, states: output_item_states, order: output_item_order)
            end

          output_items = finalize_stream_output_items(output_item_states, output_item_order)
          if response.respond_to?(:body) && response.body.is_a?(Hash)
            body_output_items = output_items_from_body(response.body)
            output_items = merge_stream_output_items_with_body(output_items, body_output_items) if body_output_items.any?
            output_items = body_output_items if output_items.empty?
            full = output_text_from_body(response.body) if full.empty?
            last_usage ||= usage_from_body(response.body)
          end

          ResponsesResult.new(output_text: full, output_items: output_items, usage: last_usage, response: response)
        else
          response = responses_create(**request)
          body = response.body.is_a?(Hash) ? response.body : {}
          ResponsesResult.new(
            output_text: output_text_from_body(body),
            output_items: output_items_from_body(body),
            usage: usage_from_body(body),
            response: response
          )
        end
      end

      private

      def base_url
        config.base_url
      end

      def post_json(path, body, raise_on_http_error: nil)
        request_json(
          method: :post,
          url: "#{base_url}#{path}",
          headers: config.headers,
          body: body,
          expect_json: true,
          raise_on_http_error: raise_on_http_error,
        )
      end

      def post_json_stream(path, body, raise_on_http_error: nil, &on_event)
        if base_url.nil? || base_url.empty?
          raise SimpleInference::ConfigurationError, "base_url is required"
        end

        url = "#{base_url}#{path}"
        validate_url!(url)

        headers = config.headers.merge(
          "Content-Type" => "application/json",
          "Accept" => "text/event-stream, application/json"
        )
        payload = serialize_json_body(body)

        request_env = {
          method: :post,
          url: url,
          headers: headers,
          body: payload,
          timeout: config.timeout,
          open_timeout: config.open_timeout,
          read_timeout: config.read_timeout,
        }

        handle_stream_response(request_env, raise_on_http_error: raise_on_http_error, &on_event)
      end

      def handle_stream_response(request_env, raise_on_http_error:, &on_event)
        sse_buffer = +""
        sse_done = false
        streamed = false

        raw_response =
          @adapter.call_stream(request_env) do |chunk|
            streamed = true
            next if sse_done

            sse_buffer << chunk.to_s
            sse_done = consume_sse_buffer!(sse_buffer, &on_event) || sse_done
          end

        status = raw_response[:status]
        headers = (raw_response[:headers] || {}).transform_keys { |k| k.to_s.downcase }
        body = raw_response[:body]
        body_str = body.nil? ? "" : body.to_s

        content_type = headers["content-type"].to_s

        # Streaming case.
        if status >= 200 && status < 300 && (content_type.include?("text/event-stream") || sse_like_body?(body_str))
          unless streamed
            buffer = body_str.dup
            consume_sse_buffer!(buffer, &on_event)
          end

          return Response.new(status: status, headers: headers, body: nil)
        end

        should_parse_json = content_type.include?("json") || json_like_body?(body_str)
        parsed_body =
          if should_parse_json
            begin
              parse_json(body_str)
            rescue SimpleInference::DecodeError
              status >= 200 && status < 300 ? raise : body_str
            end
          else
            body_str
          end

        response = Response.new(status: status, headers: headers, body: parsed_body, raw_body: body_str)
        maybe_raise_http_error(response: response, raise_on_http_error: raise_on_http_error, ignore_streaming_unsupported: false)
        response
      rescue Timeout::Error => e
        raise SimpleInference::TimeoutError, e.message
      rescue SocketError, SystemCallError => e
        raise SimpleInference::ConnectionError, e.message
      end

      def extract_sse_blocks!(buffer)
        blocks = []

        loop do
          idx_lf = buffer.index("\n\n")
          idx_crlf = buffer.index("\r\n\r\n")

          idx = [idx_lf, idx_crlf].compact.min
          break if idx.nil?

          sep_len = (idx == idx_crlf) ? 4 : 2
          blocks << buffer.slice!(0, idx)
          buffer.slice!(0, sep_len)
        end

        blocks
      end

      def consume_sse_buffer!(buffer, &on_event)
        done = false

        extract_sse_blocks!(buffer).each do |block|
          data = sse_data_from_block(block)
          next if data.nil?

          payload = data.strip
          next if payload.empty?
          if payload == "[DONE]"
            done = true
            buffer.clear
            break
          end

          on_event&.call(parse_json_event(payload))
        end

        done
      end

      def sse_data_from_block(block)
        return nil if block.nil? || block.empty?

        data_lines = []
        block.split(/\r?\n/).each do |line|
          next if line.nil? || line.empty?
          next if line.start_with?(":")
          next unless line.start_with?("data:")

          data_lines << (line[5..]&.lstrip).to_s
        end

        return nil if data_lines.empty?

        data_lines.join("\n")
      end

      def sse_like_body?(body_str)
        body = body_str.to_s.lstrip
        return false if body.empty?

        (body.start_with?("data:", "event:") || body.include?("\ndata:") || body.include?("\nevent:")) &&
          (body.include?("\n\n") || body.include?("\r\n\r\n"))
      end

      def json_like_body?(body_str)
        body = body_str.to_s.lstrip
        return false if body.empty?

        body.start_with?("{", "[")
      end

      def parse_json_event(payload)
        JSON.parse(payload)
      rescue JSON::ParserError => e
        raise SimpleInference::DecodeError, "Failed to parse SSE JSON event: #{e.message}"
      end

      def output_text_delta(event)
        event = event.body if event.respond_to?(:body)
        return nil unless event.is_a?(Hash)

        case event["type"].to_s
        when "response.output_text.delta"
          event["delta"].to_s
        else
          nil
        end
      end

      def usage_from_event(event)
        event = event.body if event.respond_to?(:body)
        return nil unless event.is_a?(Hash)

        case event["type"].to_s
        when "response.completed"
          usage = event.dig("response", "usage") || event["usage"]
          usage.is_a?(Hash) ? usage : nil
        else
          nil
        end
      end

      def collect_output_item_event!(event, states:, order:)
        event = event.body if event.respond_to?(:body)
        return unless event.is_a?(Hash)

        case event["type"].to_s
        when "response.output_item.added"
          item = event["item"]
          return unless item.is_a?(Hash)

          key = output_item_key(item, fallback: event["item_id"])
          return if key.nil?

          existing = states[key] || {}
          normalized = normalize_output_item_hash(item)
          merged = existing.merge(normalized)
          merged["arguments"] = existing["arguments"].to_s if normalized["type"].to_s == "function_call" && normalized["arguments"].to_s.empty? && existing["arguments"]
          merged["output_index"] = Integer(event["output_index"], exception: false) || existing["output_index"]
          states[key] = merged
          order << key unless order.include?(key)
        when "response.output_item.done"
          item = event["item"]
          return unless item.is_a?(Hash)

          key = output_item_key(item, fallback: event["item_id"])
          return if key.nil?

          existing = states[key] || {}
          normalized = normalize_output_item_hash(item)
          merged = existing.merge(normalized)
          merged["arguments"] = existing["arguments"].to_s if normalized["type"].to_s == "function_call" && normalized["arguments"].to_s.empty? && existing["arguments"]
          merged["output_index"] = Integer(event["output_index"], exception: false) || existing["output_index"]
          states[key] = merged
          order << key unless order.include?(key)
        when "response.function_call_arguments.delta"
          key = event["item_id"].to_s.strip
          return if key.empty?

          state = states[key] ||= { "type" => "function_call", "id" => key, "arguments" => "" }
          state["output_index"] ||= Integer(event["output_index"], exception: false)
          state["name"] ||= event["name"].to_s unless event["name"].to_s.empty?
          state["arguments"] = state["arguments"].to_s + event["delta"].to_s
          order << key unless order.include?(key)
        when "response.function_call_arguments.done"
          key = event["item_id"].to_s.strip
          return if key.empty?

          state = states[key] ||= { "type" => "function_call", "id" => key, "arguments" => "" }
          state["output_index"] ||= Integer(event["output_index"], exception: false)
          state["name"] ||= event["name"].to_s unless event["name"].to_s.empty?
          args = event["arguments"].to_s
          state["arguments"] = args unless args.empty?
          order << key unless order.include?(key)
        end
      end

      def finalize_stream_output_items(states, order)
        order
          .filter_map { |key| states[key] }
          .sort_by.with_index { |item, idx| [item["output_index"] || Float::INFINITY, idx] }
          .map do |item|
            item.reject { |key, _| key == "output_index" }
          end
      end

      def output_item_key(item, fallback:)
        id = item["id"].to_s.strip
        return id unless id.empty?

        fallback_id = fallback.to_s.strip
        return nil if fallback_id.empty?

        fallback_id
      end

      def normalize_output_item_hash(item)
        item.each_with_object({}) do |(key, value), out|
          out[key.to_s] = value
        end
      end

      def merge_stream_output_items_with_body(stream_items, body_items)
        Array(stream_items).map do |item|
          next item unless item.is_a?(Hash)
          next item unless item["type"].to_s == "function_call"

          body_item =
            Array(body_items).find do |candidate|
              next false unless candidate.is_a?(Hash)
              next false unless candidate["type"].to_s == "function_call"

              candidate_call_id = candidate["call_id"].to_s.strip
              candidate_id = candidate["id"].to_s.strip
              item_call_id = item["call_id"].to_s.strip
              item_id = item["id"].to_s.strip
              same_id = candidate_call_id == item_call_id || candidate_id == item_id || candidate_call_id == item_id
              same_shape =
                candidate["name"].to_s == item["name"].to_s &&
                  candidate["arguments"].to_s == item["arguments"].to_s
              same_id || same_shape
            end

          next item unless body_item

          item.merge(
            "id" => body_item["id"].to_s.strip.empty? ? item["id"] : body_item["id"],
            "call_id" => body_item["call_id"].to_s.strip.empty? ? item["call_id"] : body_item["call_id"],
            "name" => body_item["name"].to_s.strip.empty? ? item["name"] : body_item["name"],
            "arguments" => body_item["arguments"].to_s.strip.empty? ? item["arguments"] : body_item["arguments"],
          )
        end
      end

      def output_text_from_body(body)
        return "" unless body.is_a?(Hash)

        output = body["output"]
        return "" unless output.is_a?(Array)

        parts =
          output.flat_map do |item|
            next [] unless item.is_a?(Hash)

            content = item["content"]
            next [] unless content.is_a?(Array)

            content.filter_map do |part|
              next nil unless part.is_a?(Hash)
              next nil unless part["type"].to_s == "output_text"

              part["text"].to_s
            end
          end

        parts.join
      end

      def output_items_from_body(body)
        return [] unless body.is_a?(Hash)
        output = body["output"]
        return [] unless output.is_a?(Array)

        output.filter_map { |item| item.is_a?(Hash) ? item : nil }
      end

      def usage_from_body(body)
        return nil unless body.is_a?(Hash)
        usage = body["usage"]
        usage.is_a?(Hash) ? usage : nil
      end
    end
  end
end
