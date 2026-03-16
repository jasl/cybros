require "json"
require "net/http"
require "securerandom"
require "uri"

module Cybros
  module Agents
    module Claw
      module Tools
        class MemoryTools
          VALID_SCOPES = %w[root conversation lane].freeze
          DEFAULT_SEARCH_SCOPES = %w[lane conversation root].freeze

          def initialize(callback_session:)
            @callback_session = callback_session.is_a?(Hash) ? callback_session.deep_stringify_keys : {}
          end

          def call(logical_tool_name:, arguments:, tool_call_id:)
            case logical_tool_name.to_s
            when "memory_get"
              memory_get(arguments)
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

          def memory_get(arguments)
            scope = normalize_scope(arguments["scope"], default: "conversation")
            target = normalize_target(arguments["target"])

            success_result(JSON.generate(callback_rpc("conversation.memory.get", request_payload(scope: scope, target: target))))
          rescue AgentCore::ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("memory_get failed: #{e.class}: #{e.message}")
          end

          def memory_search(arguments)
            query = arguments.fetch("query", "").to_s
            return error_result("memory_search requires query") if query.empty?

            matches = []
            scopes = normalize_search_scopes(arguments["scopes"])
            target = normalize_target(arguments["target"])

            scopes.each do |scope|
              document =
                callback_rpc(
                  "conversation.memory.get",
                  request_payload(scope: scope, target: target),
                ).fetch("document", {})

              body = document["body"].to_s
              body.each_line.with_index(1) do |line, line_number|
                next unless line.include?(query)

                matches << {
                  "scope" => document["scope"].to_s.presence || scope,
                  "path" => document["path"].to_s,
                  "line" => line_number,
                  "snippet" => line.chomp,
                }
              end
            end

            success_result(
              JSON.generate(
                {
                  "matches" => matches,
                  "truncated" => false,
                },
              ),
            )
          rescue AgentCore::ValidationError => e
            error_result(e.message, code: e.code)
          rescue StandardError => e
            error_result("memory_search failed: #{e.class}: #{e.message}")
          end

          def memory_store(arguments, tool_call_id:)
            content = arguments.fetch("content", arguments.fetch("text", "")).to_s
            return error_result("memory_store requires content") if content.empty?

            scope = normalize_scope(arguments["scope"], default: "lane")
            target = normalize_target(arguments["target"])
            mode = arguments.fetch("mode", "append").to_s

            result =
              case mode
              when "append"
                current_body =
                  callback_rpc(
                    "conversation.memory.get",
                    request_payload(scope: scope, target: target),
                  ).dig("document", "body").to_s
                appended_text = content
                appended_text = "\n#{appended_text}" if current_body.present? && !appended_text.start_with?("\n")
                callback_rpc(
                  "conversation.memory.append",
                  request_payload(
                    scope: scope,
                    target: target,
                    extra: {
                      "text" => appended_text,
                      "operation_id" => operation_id_for(tool_call_id, "append"),
                    },
                  ),
                )
              when "replace"
                callback_rpc(
                  "conversation.memory.put",
                  request_payload(
                    scope: scope,
                    target: target,
                    extra: {
                      "body" => content,
                      "operation_id" => operation_id_for(tool_call_id, "put"),
                    },
                  ),
                )
              else
                return error_result("memory_store mode must be append or replace")
              end

            success_result(JSON.generate(result.merge("mode" => mode)))
          rescue AgentCore::ValidationError => e
            error_result(e.message, code: e.code)
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

          def normalize_scope(value, default:)
            normalized = value.to_s.strip
            normalized = default if normalized.empty?
            return normalized if VALID_SCOPES.include?(normalized)

            AgentCore::ValidationError.raise!(
              "Memory scope is invalid.",
              code: "claw.memory.invalid_scope",
              details: { scope: normalized },
            )
          end

          def normalize_search_scopes(value)
            raw_scopes = value.is_a?(Array) ? value : Array(value).compact
            return DEFAULT_SEARCH_SCOPES if raw_scopes.empty?

            raw_scopes.map { |scope| normalize_scope(scope, default: "conversation") }
          end

          def normalize_target(value)
            normalized = value.to_s.strip
            return nil if normalized.casecmp("default").zero?

            normalized.presence
          end

          def request_payload(scope:, target:, extra: {})
            {}.tap do |payload|
              payload["scope"] = scope
              payload["target"] = target if target.present?
              payload.merge!(extra)
            end
          end

          def success_result(text)
            {
              "content" => [{ "type" => "text", "text" => text.to_s }],
              "error" => false,
              "metadata" => {},
            }
          end

          def error_result(text, code: nil)
            {
              "content" => [{ "type" => "text", "text" => text.to_s }],
              "error" => true,
              "metadata" => code.present? ? { "code" => code.to_s } : {},
            }
          end
        end
      end
    end
  end
end
