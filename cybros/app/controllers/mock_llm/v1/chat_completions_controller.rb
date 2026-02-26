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

        content = build_mock_content(messages)
        usage = build_usage(messages, content)

        if stream
          stream_chat_completion(model: model, content: content, usage: usage, include_usage: include_usage)
        else
          render json: build_chat_completion_response(model: model, content: content, usage: usage)
        end
      rescue ActionDispatch::Http::Parameters::ParseError, JSON::ParserError
        render_openai_error("invalid JSON body", status: :bad_request)
      end

      private

      def render_openai_error(message, status:)
        render json: { error: { message: message, type: "invalid_request_error" } }, status: status
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

      def build_mock_content(messages)
        last_user =
          messages
            .reverse
            .find { |m| m.is_a?(Hash) && m["role"].to_s == "user" }

        prompt = last_user&.fetch("content", nil).to_s.strip

        prompt = "Hello" if prompt.blank?
        "Mock: #{prompt}"
      end

      def build_usage(messages, completion)
        prompt_chars =
          messages.sum do |m|
            next 0 unless m.is_a?(Hash)

            m.fetch("content", "").to_s.length
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

      def stream_chat_completion(model:, content:, usage:, include_usage:)
        response.status = 200
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"

        id = "mockcmpl-#{SecureRandom.hex(12)}"
        created = Time.current.to_i
        delay = stream_delay_seconds

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
