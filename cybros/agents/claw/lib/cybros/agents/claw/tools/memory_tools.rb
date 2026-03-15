require "json"
require "net/http"
require "securerandom"
require "uri"

module Cybros
  module Agents
    module Claw
      module Tools
        class MemoryTools
          def initialize(callback_session:)
            @callback_session = callback_session.is_a?(Hash) ? callback_session.deep_stringify_keys : {}
          end

          def call(logical_tool_name:, arguments:, tool_call_id:)
            case logical_tool_name.to_s
            when "memory_get"
              memory_get
            when "memory_search"
              memory_search(arguments)
            when "memory_store"
              memory_store(arguments, tool_call_id: tool_call_id)
            else
              nil
            end
          end

          private

          attr_reader :callback_session

          def memory_get
            success_result(JSON.generate(callback_rpc("conversation.memory.get", {})))
          rescue StandardError => e
            error_result("memory_get failed: #{e.class}: #{e.message}")
          end

          def memory_search(arguments)
            query = arguments.fetch("query", "").to_s
            return error_result("memory_search requires query") if query.empty?

            body = callback_rpc("conversation.memory.get", {}).dig("document", "body").to_s
            matches = []

            body.each_line.with_index(1) do |line, line_number|
              next unless line.include?(query)

              matches << {
                "line" => line_number,
                "snippet" => line.chomp,
              }
            end

            success_result(
              JSON.generate(
                {
                  "matches" => matches,
                  "truncated" => false,
                },
              ),
            )
          rescue StandardError => e
            error_result("memory_search failed: #{e.class}: #{e.message}")
          end

          def memory_store(arguments, tool_call_id:)
            content = arguments.fetch("content", arguments.fetch("text", "")).to_s
            return error_result("memory_store requires content") if content.empty?

            mode = arguments.fetch("mode", "append").to_s

            result =
              case mode
              when "append"
                current_body = callback_rpc("conversation.memory.get", {}).dig("document", "body").to_s
                appended_text = content
                appended_text = "\n#{appended_text}" if current_body.present? && !appended_text.start_with?("\n")
                callback_rpc(
                  "conversation.memory.append",
                  {
                    "text" => appended_text,
                    "operation_id" => operation_id_for(tool_call_id, "append"),
                  },
                )
              when "replace"
                callback_rpc(
                  "conversation.memory.put",
                  {
                    "body" => content,
                    "operation_id" => operation_id_for(tool_call_id, "put"),
                  },
                )
              else
                return error_result("memory_store mode must be append or replace")
              end

            success_result(JSON.generate(result.merge("mode" => mode)))
          rescue StandardError => e
            error_result("memory_store failed: #{e.class}: #{e.message}")
          end

          def callback_rpc(method_name, params)
            ensure_callback_session!

            uri = URI(callback_session.fetch("endpoint"))
            request = Net::HTTP::Post.new(uri)
            request["Content-Type"] = "application/json"
            request["Authorization"] = "Bearer #{callback_session.fetch("bearer")}"
            request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => SecureRandom.uuid, "method" => method_name, "params" => params })

            response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
            raise "callback #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

            payload = JSON.parse(response.body)
            raise "callback error: #{payload.fetch("error").inspect}" if payload["error"]

            payload.fetch("result")
          end

          def ensure_callback_session!
            return if callback_session.present?

            raise "memory tools require callback_session"
          end

          def operation_id_for(tool_call_id, action)
            [tool_call_id.to_s.presence || "tool-call", "conversation-memory", action].join(":")
          end

          def success_result(text)
            {
              "content" => [{ "type" => "text", "text" => text.to_s }],
              "error" => false,
              "metadata" => {},
            }
          end

          def error_result(text)
            {
              "content" => [{ "type" => "text", "text" => text.to_s }],
              "error" => true,
              "metadata" => {},
            }
          end
        end
      end
    end
  end
end
