require "json"

module Cybros
  module Agents
    module Claw
      module Tools
        class WebTools
          def initialize(provider:)
            @provider = provider
          end

          def call(logical_tool_name:, arguments:)
            case logical_tool_name.to_s
            when "web_search"
              web_search(arguments)
            when "web_fetch"
              web_fetch(arguments)
            else
              nil
            end
          rescue WebProvider::DisabledError => e
            error_result(e.message)
          rescue StandardError => e
            error_result("#{logical_tool_name} failed: #{e.class}: #{e.message}")
          end

          private

          attr_reader :provider

          def web_search(arguments)
            payload =
              provider.search(
                query: arguments.fetch("query", "").to_s,
                count: arguments.fetch("count", WebProvider::DEFAULT_SEARCH_COUNT),
              )

            success_result(JSON.generate(payload))
          end

          def web_fetch(arguments)
            payload =
              provider.fetch(
                url: arguments.fetch("url", "").to_s,
                max_chars: arguments.fetch("max_chars", WebProvider::DEFAULT_FETCH_MAX_CHARS),
              )

            success_result(JSON.generate(payload))
          end

          def success_result(text)
            {
              "content" => [
                {
                  "type" => "text",
                  "text" => text,
                }
              ],
              "error" => false,
              "metadata" => {},
            }
          end

          def error_result(text)
            {
              "content" => [
                {
                  "type" => "text",
                  "text" => text.to_s,
                }
              ],
              "error" => true,
              "metadata" => {},
            }
          end
        end
      end
    end
  end
end
