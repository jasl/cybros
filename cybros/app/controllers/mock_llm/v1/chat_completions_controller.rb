require "shellwords"

module MockLLM
  module V1
    class ChatCompletionsController < ApplicationController
      include ActionController::Live

      def create
        payload = request.request_parameters

        model = payload["model"].to_s
        messages = normalize_messages(payload["messages"])

        return render_openai_error("model is required", status: :bad_request) if model.blank?
        unless messages.is_a?(Array) && messages.any?
          return render_openai_error("messages must be a non-empty array", status: :bad_request)
        end

        stream = boolean(payload["stream"])
        include_usage = boolean(payload.dig("stream_options", "include_usage"))

        last_user_prompt = last_user_prompt(messages)
        controls = parse_mock_controls(last_user_prompt)

        if controls[:invalid_directive]
          return render_openai_error("invalid mock directive", status: :bad_request)
        end

        if controls[:error_status]
          return render_openai_error(
            controls[:error_message] || "mock error",
            status: controls[:error_status],
            type: openai_error_type_for_status(controls[:error_status]),
          )
        end

        effective_prompt = controls[:prompt]
        content = build_mock_content(messages, prompt_override: effective_prompt)
        usage = build_usage(messages, content, prompt_override: effective_prompt)

        if stream
          stream_chat_completion(
            model: model,
            content: content,
            usage: usage,
            include_usage: include_usage,
            delay_seconds: controls[:slow_seconds],
          )
        else
          render json: build_chat_completion_response(model: model, content: content, usage: usage)
        end
      rescue ActionDispatch::Http::Parameters::ParseError, JSON::ParserError
        render_openai_error("invalid JSON body", status: :bad_request)
      end

      private

      def render_openai_error(message, status:, type: "invalid_request_error", param: nil, code: nil)
        error = { message: message, type: type }
        error[:param] = param unless param.nil?
        error[:code] = code unless code.nil?

        render json: { error: error }, status: status
      end

      def boolean(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end

      def normalize_messages(raw)
        return raw unless raw.is_a?(Array)

        raw.map do |message|
          if message.is_a?(ActionController::Parameters)
            message.to_unsafe_h
          else
            message
          end
        end
      end

      def last_user_prompt(messages)
        last_user =
          messages
            .reverse
            .find { |m| m.is_a?(Hash) && m["role"].to_s == "user" }

        last_user&.fetch("content", nil).to_s
      end

      def parse_mock_controls(prompt)
        raw = prompt.to_s
        first_line, rest = raw.split(/\r?\n/, 2)
        first_line = first_line.to_s.strip
        rest = rest.to_s

        return { prompt: raw.strip.presence || "Hello" } unless first_line.match?(/\A!mock\b/i)

        directive_body = first_line.sub(/\A!mock\b/i, "").strip

        directive_part = directive_body
        inline_prompt = ""

        if directive_body.start_with?("--")
          inline_prompt = directive_body.delete_prefix("--").lstrip
          directive_part = ""
        elsif (m = directive_body.match(/(^|\s)--\s/))
          directive_part = directive_body[0...m.begin(0)].strip
          inline_prompt = directive_body[m.end(0)..].to_s
        end

        tokens =
          if directive_part.empty?
            []
          else
            begin
              Shellwords.split(directive_part)
            rescue ArgumentError
              return { invalid_directive: true }
            end
          end

        slow_seconds = nil
        error_status = nil
        error_message = nil

        tokens.each do |t|
          key, value = t.split("=", 2)
          next if value.nil?

          case key.to_s.downcase
          when "slow"
            slow_seconds = Float(value)
            slow_seconds = 0.0 if slow_seconds.negative?
          when "error"
            status_int = Integer(value)
            error_status = status_int if status_int >= 100 && status_int <= 599
          when "message"
            error_message = value.to_s
          end
        rescue ArgumentError, TypeError
          next
        end

        slow_seconds = clamp_mock_slow_seconds(slow_seconds)

        effective_prompt =
          [inline_prompt.to_s, rest.to_s]
            .reject(&:blank?)
            .join("\n")
            .strip

        effective_prompt = "Hello" if effective_prompt.blank?

        {
          prompt: effective_prompt,
          slow_seconds: slow_seconds,
          error_status: error_status,
          error_message: error_message,
        }
      end

      def clamp_mock_slow_seconds(seconds)
        return nil if seconds.nil?

        s = seconds.to_f
        s = 0.0 if s.negative?

        # Prevent request-thread abuse via `sleep()` (ActionController::Live).
        max = ENV.fetch("MOCK_LLM_MAX_SLOW_SECONDS", "0.2").to_f
        max = 0.2 if max <= 0.0

        [s, max].min
      rescue ArgumentError, TypeError
        nil
      end

      def openai_error_type_for_status(status)
        s = status.to_i
        return "rate_limit_error" if s == 429
        return "authentication_error" if s == 401
        return "permission_error" if s == 403
        return "invalid_request_error" if s >= 400 && s < 500
        return "server_error" if s >= 500 && s < 600

        "api_error"
      end

      def build_mock_content(messages, prompt_override: nil)
        prompt = (prompt_override.presence || last_user_prompt(messages)).to_s.strip

        prompt = "Hello" if prompt.blank?

        if prompt.match?(/\A!md\b/i)
          raw = prompt.sub(/\A!md\b/i, "").strip
          raw = "Hello" if raw.blank?

          return <<~MD.strip
            # Mock Markdown

            **Prompt:** #{raw}

            - This response is deterministic (for E2E).
            - It includes markdown constructs (heading, bold, list, code).

            ```txt
            mock_llm streaming: enabled
            ```
          MD
        end

        "Mock: #{prompt}"
      end

      def build_usage(messages, completion, prompt_override: nil)
        last_user_index =
          if prompt_override.present?
            messages.rindex { |m| m.is_a?(Hash) && m["role"].to_s == "user" }
          end

        prompt_chars =
          messages.each_with_index.sum do |m, idx|
            next 0 unless m.is_a?(Hash)

            if !last_user_index.nil? && idx == last_user_index
              prompt_override.to_s.length
            else
              m.fetch("content", "").to_s.length
            end
          end

        completion_chars = completion.to_s.length

        prompt_tokens = (prompt_chars / 4.0).ceil
        completion_tokens = (completion_chars / 4.0).ceil

        {
          "prompt_tokens" => prompt_tokens,
          "completion_tokens" => completion_tokens,
          "total_tokens" => prompt_tokens + completion_tokens,
        }
      end

      def build_chat_completion_response(model:, content:, usage:)
        {
          id: "mockcmpl-#{SecureRandom.hex(12)}",
          object: "chat.completion",
          created: Time.current.to_i,
          model: model,
          choices: [
            {
              index: 0,
              message: { role: "assistant", content: content },
              finish_reason: "stop",
            },
          ],
          usage: usage,
        }
      end

      def stream_chat_completion(model:, content:, usage:, include_usage:, delay_seconds: nil)
        response.status = 200
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"

        id = "mockcmpl-#{SecureRandom.hex(12)}"
        created = Time.current.to_i
        delay = delay_seconds.nil? ? stream_delay_seconds : delay_seconds.to_f

        write_sse_event(
          "id" => id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [
            { "index" => 0, "delta" => { "role" => "assistant" }, "finish_reason" => nil },
          ],
        )

        chunk_strings(content).each do |chunk|
          write_sse_event(
            "id" => id,
            "object" => "chat.completion.chunk",
            "created" => created,
            "model" => model,
            "choices" => [
              { "index" => 0, "delta" => { "content" => chunk }, "finish_reason" => nil },
            ],
          )

          sleep(delay) if delay.positive?
        end

        final_event = {
          "id" => id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [
            { "index" => 0, "delta" => {}, "finish_reason" => "stop" },
          ],
        }
        final_event["usage"] = usage if include_usage

        write_sse_event(final_event)
        response.stream.write("data: [DONE]\n\n")
      rescue IOError, ActionController::Live::ClientDisconnected
        nil
      ensure
        begin
          response.stream.close
        rescue IOError, ActionController::Live::ClientDisconnected
          nil
        end
      end

      def stream_delay_seconds
        return 0.0 if Rails.env.test?

        raw = ENV.fetch("MOCK_LLM_STREAM_DELAY", "0.02")
        Float(raw)
      rescue ArgumentError, TypeError
        0.0
      end

      def chunk_strings(text)
        text.to_s.scan(/.{1,18}/m)
      end

      def write_sse_event(event_hash)
        response.stream.write("data: #{JSON.generate(event_hash)}\n\n")
      end
    end
  end
end
