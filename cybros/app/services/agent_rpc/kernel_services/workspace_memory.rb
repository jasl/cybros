module AgentRPC
  module KernelServices
    class WorkspaceMemory
      DEFAULT_TARGET = "MEMORY.md".freeze
      VALID_SCOPES = %w[root conversation lane].freeze

      def self.get(conversation:, lane:, scope:, target: nil)
        new(conversation: conversation, lane: lane, scope: scope, target: target).get
      end

      def self.put!(conversation:, lane:, scope:, body:, target: nil)
        new(conversation: conversation, lane: lane, scope: scope, target: target).put!(body: body)
      end

      def self.append!(conversation:, lane:, scope:, text:, target: nil)
        new(conversation: conversation, lane: lane, scope: scope, target: target).append!(text: text)
      end

      def initialize(conversation:, lane:, scope:, target: nil)
        @conversation = conversation
        @lane = lane
        @scope = normalize_scope(scope)
        @target = normalize_target(target)
      end

      def get
        document_response(body: read_body, materialized: document_path.file?)
      end

      def put!(body:)
        write_body(body.to_s)
        document_response(body: body.to_s, materialized: true)
      end

      def append!(text:)
        persisted_body = read_body + text.to_s
        write_body(persisted_body)
        document_response(body: persisted_body, materialized: true)
      end

      private

        attr_reader :conversation, :lane, :scope, :target

        def normalize_scope(value)
          normalized = value.to_s.strip
          normalized = "conversation" if normalized.empty?
          return normalized if VALID_SCOPES.include?(normalized)

          AgentCore::ValidationError.raise!(
            "Memory scope is invalid.",
            code: "claw.memory.invalid_scope",
            details: { scope: normalized },
          )
        end

        def normalize_target(value)
          normalized = value.to_s.strip
          normalized = "" if normalized.casecmp("default").zero?
          normalized = DEFAULT_TARGET if normalized.empty?
          normalized
        end

        def document_root
          case scope
          when "root"
            conversation.agent.workspace_root_path
          when "conversation"
            conversation.workspace_root_path
          when "lane"
            target_lane = lane || conversation.chat_lane
            conversation.lane_workspace_root_path(lane_id: target_lane.id)
          end
        end

        def document_path
          expanded = document_root.join(target).expand_path
          root = document_root.expand_path
          return expanded if expanded == root || expanded.to_s.start_with?(root.to_s + File::SEPARATOR)

          AgentCore::ValidationError.raise!(
            "Memory target escapes the selected scope.",
            code: "claw.memory.invalid_target",
            details: { scope: scope, target: target },
          )
        end

        def read_body
          return "" unless document_path.file?

          document_path.read
        end

        def write_body(body)
          document_path.dirname.mkpath
          document_path.write(body.to_s)
        end

        def document_response(body:, materialized:)
          {
            "document" => {
              "kind" => "workspace_memory",
              "scope" => scope,
              "target" => target,
              "path" => document_path.to_s,
              "body" => body.to_s,
              "materialized" => materialized,
            },
          }
        end
    end
  end
end
