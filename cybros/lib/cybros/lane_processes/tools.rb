require "json"

module Cybros
  module LaneProcesses
    module Tools
      DEFAULT_LOG_TAIL_LINES = 200

      module_function

      def build
        [
          build_start_tool,
          build_list_tool,
          build_read_log_tool,
          build_stop_tool,
        ]
      end

      def build_start_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "start_background_process",
          description: "Start a long-running background process for the current conversation lane.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "command" => { type: "string" },
              "cwd" => { type: "string" },
              "title" => { type: "string" },
              "env" => { type: "object", additionalProperties: { type: "string" } },
              "port_hints" => { type: "array", items: { type: "integer", minimum: 1 } },
            },
            required: ["command"],
          },
          metadata: { source: :cybros, category: :lane_processes, permission_class: "boundary" },
        ) do |args, context:|
          task_node = current_task_node!(context, code_prefix: "cybros.lane_processes.start_background_process")
          conversation = conversation_for!(task_node, code_prefix: "cybros.lane_processes.start_background_process")
          lane_process =
            ::LaneProcesses::Launcher.call!(
              conversation: conversation,
              lane: task_node.lane,
              owner_turn: task_node.turn,
              started_by_type: LaneProcess::AGENT,
              command: args.fetch("command"),
              cwd: args["cwd"],
              env: args["env"],
              title: args["title"],
              port_hints: args["port_hints"],
            )

          payload = serialize_lane_process(lane_process)
          AgentCore::Resources::Tools::ToolResult.success(
            text: JSON.generate(payload),
            metadata: payload,
          )
        end
      end
      private_class_method :build_start_tool

      def build_list_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "list_lane_processes",
          description: "List background processes tracked for the current conversation.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "include_terminal" => { type: "boolean" },
            },
          },
          metadata: { source: :cybros, category: :lane_processes, permission_class: "read" },
        ) do |args, context:|
          task_node = current_task_node!(context, code_prefix: "cybros.lane_processes.list_lane_processes")
          conversation = conversation_for!(task_node, code_prefix: "cybros.lane_processes.list_lane_processes")
          ::LaneProcesses::Reconciler.call!(conversation: conversation)

          scope = conversation.lane_processes.recent_first
          scope = scope.where.not(status: LaneProcess::TERMINAL_STATUSES) unless args["include_terminal"] == true

          payload = {
            "items" => scope.map { |lane_process| serialize_lane_process(lane_process, current_lane: task_node.lane) },
          }

          AgentCore::Resources::Tools::ToolResult.success(
            text: JSON.generate(payload),
            metadata: payload,
          )
        end
      end
      private_class_method :build_list_tool

      def build_read_log_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "read_lane_process_log",
          description: "Read the tail of a tracked background process log file.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "lane_process_id" => { type: "string" },
              "tail_lines" => { type: "integer", minimum: 1, maximum: 500 },
            },
            required: ["lane_process_id"],
          },
          metadata: { source: :cybros, category: :lane_processes, permission_class: "read" },
        ) do |args, context:|
          task_node = current_task_node!(context, code_prefix: "cybros.lane_processes.read_lane_process_log")
          conversation = conversation_for!(task_node, code_prefix: "cybros.lane_processes.read_lane_process_log")
          lane_process = lane_process_for!(conversation: conversation, id: args.fetch("lane_process_id"), code_prefix: "cybros.lane_processes.read_lane_process_log")
          authorize_lane_management!(task_node: task_node, lane_process: lane_process, code_prefix: "cybros.lane_processes.read_lane_process_log")
          lines = ::LaneProcesses::LogReader.call(lane_process: lane_process, tail_lines: args.fetch("tail_lines", DEFAULT_LOG_TAIL_LINES))

          payload = {
            "lane_process_id" => lane_process.id,
            "log_path" => lane_process.log_path,
            "lines" => lines,
          }

          AgentCore::Resources::Tools::ToolResult.success(
            text: JSON.generate(payload),
            metadata: payload,
          )
        end
      end
      private_class_method :build_read_log_tool

      def build_stop_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "stop_lane_process",
          description: "Stop a tracked background process for the current conversation.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "lane_process_id" => { type: "string" },
            },
            required: ["lane_process_id"],
          },
          metadata: { source: :cybros, category: :lane_processes, permission_class: "boundary" },
        ) do |args, context:|
          task_node = current_task_node!(context, code_prefix: "cybros.lane_processes.stop_lane_process")
          conversation = conversation_for!(task_node, code_prefix: "cybros.lane_processes.stop_lane_process")
          lane_process = lane_process_for!(conversation: conversation, id: args.fetch("lane_process_id"), code_prefix: "cybros.lane_processes.stop_lane_process")
          authorize_lane_management!(task_node: task_node, lane_process: lane_process, code_prefix: "cybros.lane_processes.stop_lane_process")
          payload = ::LaneProcesses::Stopper.call!(lane_process: lane_process)

          AgentCore::Resources::Tools::ToolResult.success(
            text: JSON.generate(payload),
            metadata: payload,
          )
        end
      end
      private_class_method :build_stop_tool

      def current_task_node!(context, code_prefix:)
        node_id = context&.attributes&.dig(:dag, :node_id).to_s
        node = DAG::Node.find_by(id: node_id)
        return node if node.present?

        AgentCore::ValidationError.raise!(
          "lane process tools require a current DAG task node",
          code: "#{code_prefix}.current_task_node_required",
        )
      end
      private_class_method :current_task_node!

      def conversation_for!(task_node, code_prefix:)
        conversation = task_node.graph.attachable
        return conversation if conversation.is_a?(Conversation)

        AgentCore::ValidationError.raise!(
          "lane process tools require a Conversation-backed graph",
          code: "#{code_prefix}.conversation_required",
          details: { attachable_type: task_node.graph.attachable_type.to_s },
        )
      end
      private_class_method :conversation_for!

      def lane_process_for!(conversation:, id:, code_prefix:)
        lane_process = conversation.lane_processes.find_by(id: id.to_s)
        return lane_process if lane_process.present?

        AgentCore::ValidationError.raise!(
          "lane_process_id is invalid",
          code: "#{code_prefix}.lane_process_not_found",
          details: { lane_process_id: id.to_s },
        )
      end
      private_class_method :lane_process_for!

      def authorize_lane_management!(task_node:, lane_process:, code_prefix:)
        return if lane_process.manageable_by_lane?(task_node.lane)

        AgentCore::ValidationError.raise!(
          "The current lane cannot manage this background process.",
          code: "#{code_prefix}.lane_process_not_manageable",
          details: {
            lane_process_id: lane_process.id,
            lane_id: lane_process.lane_id,
            current_lane_id: task_node.lane_id,
          },
        )
      end
      private_class_method :authorize_lane_management!

      def serialize_lane_process(lane_process, current_lane: nil)
        manageable = current_lane.present? ? lane_process.manageable_by_lane?(current_lane) : true
        payload = {
          "id" => lane_process.id,
          "lane_id" => lane_process.lane_id,
          "owner_turn_id" => lane_process.owner_turn_id,
          "manageable" => manageable,
          "title" => lane_process.display_title,
          "command" => lane_process.command,
          "cwd" => lane_process.cwd,
          "status" => lane_process.status,
          "pid" => lane_process.pid,
          "pgid" => lane_process.pgid,
          "port_hints" => lane_process.port_hints,
          "started_at" => lane_process.started_at&.iso8601,
          "ended_at" => lane_process.ended_at&.iso8601,
        }.compact

        payload["log_path"] = lane_process.log_path if manageable
        payload
      end
      private_class_method :serialize_lane_process
    end
  end
end
