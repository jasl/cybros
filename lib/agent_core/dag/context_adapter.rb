# frozen_string_literal: true

require "json"

module AgentCore
  module DAG
    class ContextAdapter
      Context =
        Data.define(
          :system_prompt,
          :messages,
          :latest_user_message,
        )

      def initialize(context_nodes:)
        @context_nodes = Array(context_nodes)
      end

      def call
        system_parts = []
        messages = []
        latest_user_message = nil

        @context_nodes.each do |node|
          node_type = node.fetch("node_type").to_s
          payload = node.fetch("payload") { {} }
          input = payload.fetch("input") { {} }
          output = payload.fetch("output") { {} }
          metadata = node.fetch("metadata") { {} }

          case node_type
          when "system_message", "developer_message"
            text = input.is_a?(Hash) ? input.fetch("content", "").to_s : ""
            text = text.strip
            system_parts << text unless text.empty?
          when "summary"
            summary_text = output.is_a?(Hash) ? output.fetch("content", "").to_s : ""
            summary_text = summary_text.strip
            unless summary_text.empty?
              messages << Message.new(role: :system, content: "<summary>\n#{summary_text}\n</summary>")
            end
          when "user_message"
            msg = message_from_payload(role: :user, container: input)
            messages << msg
            latest_user_message = msg
          when "agent_message", "character_message"
            msg =
              if output.is_a?(Hash) && output["message"]
                message_from_serialized(output["message"])
              else
                message_from_payload(role: :assistant, container: output)
              end
            messages << msg
          when "task"
            tool_message = tool_result_message_from_task(node, input: input, output: output, metadata: metadata)
            messages << tool_message if tool_message
          else
            # Unknown node types are ignored in prompt assembly.
          end
        end

        system_prompt = system_parts.join("\n\n")

        Context.new(
          system_prompt: system_prompt,
          messages: messages,
          latest_user_message: latest_user_message,
        )
      end

      private

        def message_from_payload(role:, container:)
          if container.is_a?(Hash) && container["message"].is_a?(Hash)
            msg = message_from_serialized(container["message"])
            if msg.role == role
              return msg
            else
              return Message.new(role: role, content: msg.content, tool_calls: msg.tool_calls, tool_call_id: msg.tool_call_id, name: msg.name, metadata: msg.metadata)
            end
          end

          content =
            if container.is_a?(Hash)
              container.fetch("content", "").to_s
            else
              ""
            end

          Message.new(role: role, content: content)
        rescue StandardError
          Message.new(role: role, content: "")
        end

        def message_from_serialized(value)
          hash =
            case value
            when Hash
              value
            when String
              JSON.parse(value)
            else
              raise ArgumentError, "message payload must be a Hash or JSON String (got #{value.class})"
            end

          Message.from_h(hash)
        rescue JSON::ParserError => e
          Message.new(role: :assistant, content: "[invalid message JSON: #{e.message}]")
        rescue StandardError => e
          Message.new(role: :assistant, content: "[invalid message: #{e.class}]")
        end

        def tool_result_message_from_task(node, input:, output:, metadata:)
          _ = node
          input = input.is_a?(Hash) ? input : {}
          output = output.is_a?(Hash) ? output : {}
          metadata = metadata.is_a?(Hash) ? metadata : {}

          tool_call_id = input.fetch("tool_call_id", nil).to_s.strip
          name = input.fetch("name", input.fetch("requested_name", "")).to_s.strip

          state = node.fetch("state").to_s

          result =
            case state
            when ::DAG::Node::FINISHED
              AgentCore::Resources::Tools::ToolResult.from_h(output.fetch("result"))
            when ::DAG::Node::AWAITING_APPROVAL
              AgentCore::Resources::Tools::ToolResult.error(text: "Tool '#{name}' is awaiting approval.")
            when ::DAG::Node::REJECTED
              reason = metadata["reason"].to_s
              reason = "rejected" if reason.strip.empty?
              AgentCore::Resources::Tools::ToolResult.error(text: "Tool '#{name}' was denied (reason=#{reason}).")
            when ::DAG::Node::ERRORED
              error = metadata["error"].to_s
              error = "errored" if error.strip.empty?
              AgentCore::Resources::Tools::ToolResult.error(text: "Tool '#{name}' errored (#{error}).")
            when ::DAG::Node::STOPPED
              reason = metadata["reason"].to_s
              reason = "stopped" if reason.strip.empty?
              AgentCore::Resources::Tools::ToolResult.error(text: "Tool '#{name}' was stopped (reason=#{reason}).")
            when ::DAG::Node::SKIPPED
              reason = metadata["reason"].to_s
              reason = "skipped" if reason.strip.empty?
              AgentCore::Resources::Tools::ToolResult.error(text: "Tool '#{name}' was skipped (reason=#{reason}).")
            else
              AgentCore::Resources::Tools::ToolResult.error(text: "Tool '#{name}' is in state=#{state}.")
            end

          content = tool_result_text_for_message(result, name: name)

          if tool_call_id.empty?
            Message.new(role: :system, content: content)
          else
            Message.new(role: :tool_result, content: content, tool_call_id: tool_call_id)
          end
        rescue StandardError => e
          Message.new(role: :system, content: "Tool result unavailable (#{e.class}).")
        end

        def tool_result_text_for_message(result, name:)
          text = result.text.to_s
          text = "[tool: #{name}]\n#{text}" unless name.to_s.strip.empty?

          if result.has_non_text_content?
            text << "\n\n[non-text tool output omitted]"
          end

          text
        end
    end
  end
end
