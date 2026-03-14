module Cybros
  module Bootstrap
    module Tools
      GENERIC_TITLES = %w[conversation chat branch].freeze

      module_function

      def build
        [
          build_seed_message_tool,
          build_bootstrap_state_tool,
          build_generate_title_tool,
          build_enqueue_lane_summary_tool,
        ]
      end

      def build_seed_message_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "cybros_seed_message",
          description: "Create a visible bootstrap assistant message on the current lane.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "conversation_id" => { type: "string" },
              "lane_id" => { type: "string" },
              "content" => { type: "string" },
              "role" => { type: "string" },
              "exclude_from_context" => { type: "boolean" },
              "metadata" => { type: "object" },
            },
            required: ["content"],
          },
          metadata: { source: :cybros, category: :bootstrap, permission_class: "write", execution_mode: "serial" },
        ) do |args, context:|
          task_node = current_task_node!(context)
          conversation = conversation_for!(task_node: task_node, conversation_id: args["conversation_id"])
          lane = lane_for!(task_node: task_node, lane_id: args["lane_id"])
          content = args.fetch("content").to_s.strip

          AgentCore::ValidationError.raise!(
            "bootstrap seed message content must be present",
            code: "cybros.bootstrap.seed_message.content_blank",
          ) if content.blank?

          message_node = existing_sequence_agent_child(task_node)

          if message_node.nil?
            graph = task_node.graph
            graph.mutate!(turn_id: task_node.turn_id) do |m|
              message_node =
                m.create_node(
                  node_type: Messages::AgentMessage.node_type_key,
                  state: DAG::Node::FINISHED,
                  lane_id: lane.id,
                  body_output: { "content" => content },
                  metadata: normalize_metadata(args["metadata"]).merge(
                    "generated_by" => "cybros_seed_message",
                    "source_task_id" => task_node.id,
                    "transcript_visible" => true,
                    "transcript_preview" => content,
                    "bootstrap_message_role" => args["role"].to_s.presence || "assistant",
                  ),
                )
              m.create_edge(from_node: task_node, to_node: message_node, edge_type: DAG::Edge::SEQUENCE)
            end
          end

          if ActiveModel::Type::Boolean.new.cast(args["exclude_from_context"])
            if message_node.can_exclude_from_context?
              message_node.exclude_from_context!
            else
              message_node.request_exclude_from_context!
            end
          end

          AgentCore::Resources::Tools::ToolResult.success(
            text: content,
            metadata: {
              "conversation_id" => conversation.id,
              "lane_id" => lane.id,
              "message_node_id" => message_node.id,
              "generated_by" => "cybros_seed_message",
            },
          )
        end
      end
      private_class_method :build_seed_message_tool

      def build_bootstrap_state_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "cybros_bootstrap_state",
          description: "Apply conversation and lane bootstrap state through a DAG-visible authority task.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "conversation_id" => { type: "string" },
              "lane_id" => { type: "string" },
              "public_settings_patch" => { type: "object" },
              "agent_config_patch" => { type: "object" },
              "kv_ops" => { type: "array", items: { type: "object" } },
              "prompt_buffer_ops" => { type: "array", items: { type: "object" } },
            },
          },
          metadata: { source: :cybros, category: :bootstrap, permission_class: "write", execution_mode: "serial" },
        ) do |args, context:|
          task_node = current_task_node!(context)
          conversation = conversation_for!(task_node: task_node, conversation_id: args["conversation_id"])
          lane = lane_for!(task_node: task_node, lane_id: args["lane_id"])

          public_settings_patch = normalize_hash(args["public_settings_patch"])
          agent_config_patch = normalize_hash(args["agent_config_patch"])
          kv_ops = normalize_kv_ops(args["kv_ops"])
          prompt_buffer_ops = normalize_prompt_buffer_ops(args["prompt_buffer_ops"])

          if public_settings_patch.blank? && agent_config_patch.blank? && kv_ops.empty? && prompt_buffer_ops.empty?
            AgentCore::ValidationError.raise!(
              "bootstrap state requires at least one mutation",
              code: "cybros.bootstrap.bootstrap_state.mutations_required",
            )
          end

          ApplicationRecord.transaction do
            apply_public_settings_patch!(conversation: conversation, patch: public_settings_patch)
            apply_agent_config_patch!(conversation: conversation, patch: agent_config_patch)
            apply_kv_ops!(lane: lane, task_node: task_node, operations: kv_ops)
            apply_prompt_buffer_ops!(lane: lane, operations: prompt_buffer_ops)
          end

          AgentCore::Resources::Tools::ToolResult.success(
            text: "Bootstrap state applied.",
            metadata: {
              "conversation_id" => conversation.id,
              "lane_id" => lane.id,
              "public_settings_patch" => public_settings_patch,
              "agent_config_patch" => agent_config_patch,
              "kv_ops_count" => kv_ops.length,
              "prompt_buffer_ops_count" => prompt_buffer_ops.length,
            },
          )
        end
      end
      private_class_method :build_bootstrap_state_tool

      def build_generate_title_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "cybros_generate_title",
          description: "Generate and apply a conversation title from the first persisted user-authored message.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "conversation_id" => { type: "string" },
              "lane_id" => { type: "string" },
              "user_node_id" => { type: "string" },
            },
            required: ["user_node_id"],
          },
          metadata: { source: :cybros, category: :bootstrap, permission_class: "write" },
        ) do |args, context:|
          task_node = current_task_node!(context)
          conversation = conversation_for!(task_node: task_node, conversation_id: args["conversation_id"])
          lane = lane_for!(task_node: task_node, lane_id: args["lane_id"])
          user_node = resolve_user_node!(conversation: conversation, lane: lane, user_node_id: args["user_node_id"])

          current_title = conversation.title.to_s
          if generic_title?(current_title)
            candidate = title_candidate_for(user_node.body_input["content"])
            conversation.update!(title: candidate) if candidate.present?
          end

          AgentCore::Resources::Tools::ToolResult.success(
            text: conversation.reload.title.to_s,
            metadata: {
              "conversation_id" => conversation.id,
              "lane_id" => lane.id,
              "user_node_id" => user_node.id,
              "title" => conversation.title,
              "noop" => !generic_title?(current_title),
            },
          )
        end
      end
      private_class_method :build_generate_title_tool

      def build_enqueue_lane_summary_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "cybros_enqueue_lane_summary",
          description: "Record a DAG-visible lane summary bootstrap task.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "conversation_id" => { type: "string" },
              "lane_id" => { type: "string" },
            },
          },
          metadata: { source: :cybros, category: :bootstrap, permission_class: "write" },
        ) do |args, context:|
          task_node = current_task_node!(context)
          conversation = conversation_for!(task_node: task_node, conversation_id: args["conversation_id"])
          lane = lane_for!(task_node: task_node, lane_id: args["lane_id"])

          AgentCore::Resources::Tools::ToolResult.success(
            text: "Lane summary bootstrap recorded.",
            metadata: {
              "conversation_id" => conversation.id,
              "lane_id" => lane.id,
              "generated_by" => "cybros_enqueue_lane_summary",
            },
          )
        end
      end
      private_class_method :build_enqueue_lane_summary_tool

      def current_task_node!(context)
        node_id = context&.attributes&.dig(:dag, :node_id).to_s
        node = DAG::Node.find_by(id: node_id)
        return node if node

        AgentCore::ValidationError.raise!(
          "bootstrap tools require a current DAG task node",
          code: "cybros.bootstrap.current_task_node_required",
        )
      end
      private_class_method :current_task_node!

      def conversation_for!(task_node:, conversation_id:)
        conversation = task_node.lane&.attachable
        conversation = task_node.graph.attachable unless conversation.is_a?(Conversation)
        unless conversation.is_a?(Conversation)
          AgentCore::ValidationError.raise!(
            "bootstrap tools require a Conversation-backed DAG graph",
            code: "cybros.bootstrap.conversation_required",
            details: { attachable_type: task_node.graph.attachable_type.to_s },
          )
        end

        expected_id = conversation_id.to_s.presence
        if expected_id.present? && expected_id != conversation.id.to_s
          AgentCore::ValidationError.raise!(
            "bootstrap tool conversation_id is invalid",
            code: "cybros.bootstrap.conversation_id_invalid",
            details: { conversation_id: expected_id, expected_conversation_id: conversation.id.to_s },
          )
        end

        conversation
      end
      private_class_method :conversation_for!

      def lane_for!(task_node:, lane_id:)
        lane = task_node.lane
        expected_id = lane_id.to_s.presence
        if expected_id.present? && expected_id != lane.id.to_s
          AgentCore::ValidationError.raise!(
            "bootstrap tool lane_id is invalid",
            code: "cybros.bootstrap.lane_id_invalid",
            details: { lane_id: expected_id, expected_lane_id: lane.id.to_s },
          )
        end

        lane
      end
      private_class_method :lane_for!

      def resolve_user_node!(conversation:, lane:, user_node_id:)
        node = conversation.root_graph.nodes.active.find_by(id: user_node_id.to_s)
        if node.nil? || node.lane_id.to_s != lane.id.to_s || node.node_type.to_s != Messages::UserMessage.node_type_key
          AgentCore::ValidationError.raise!(
            "bootstrap title generation requires a valid user_node_id on the current lane",
            code: "cybros.bootstrap.generate_title.user_node_id_invalid",
            details: { user_node_id: user_node_id.to_s, lane_id: lane.id.to_s },
          )
        end

        node
      end
      private_class_method :resolve_user_node!

      def existing_sequence_agent_child(task_node)
        child_ids =
          task_node.graph.edges.active
            .where(from_node_id: task_node.id, edge_type: DAG::Edge::SEQUENCE)
            .order(:id)
            .pluck(:to_node_id)

        return nil if child_ids.empty?

        task_node.graph.nodes.active
          .where(id: child_ids, node_type: Messages::AgentMessage.node_type_key)
          .order(:id)
          .last
      end
      private_class_method :existing_sequence_agent_child

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end
      private_class_method :normalize_hash

      def normalize_metadata(value)
        normalize_hash(value)
      end
      private_class_method :normalize_metadata

      def normalize_kv_ops(value)
        Array(value).map do |operation|
          raw = operation.is_a?(Hash) ? operation.deep_stringify_keys : {}
          op = raw["op"].to_s
          key = raw["key"].to_s.strip

          AgentCore::ValidationError.raise!(
            "bootstrap kv op must include a valid key",
            code: "cybros.bootstrap.bootstrap_state.kv_key_invalid",
          ) if key.blank?

          case op
          when "set"
            { "op" => "set", "key" => key, "value" => normalize_json(raw["value"]) }
          when "delete"
            { "op" => "delete", "key" => key }
          else
            AgentCore::ValidationError.raise!(
              "bootstrap kv op is invalid",
              code: "cybros.bootstrap.bootstrap_state.kv_op_invalid",
              details: { op: op },
            )
          end
        end
      end
      private_class_method :normalize_kv_ops

      def normalize_prompt_buffer_ops(value)
        Array(value).map do |operation|
          raw = operation.is_a?(Hash) ? operation.deep_stringify_keys : {}

          case raw["op"].to_s
          when "put"
            entry = normalize_prompt_buffer_entry(raw["entry"])
            { "op" => "put", "entry" => entry }
          when "delete"
            entry_id = raw["entry_id"].to_s.strip
            AgentCore::ValidationError.raise!(
              "bootstrap prompt-buffer delete requires entry_id",
              code: "cybros.bootstrap.bootstrap_state.prompt_buffer_entry_id_blank",
            ) if entry_id.blank?
            { "op" => "delete", "entry_id" => entry_id }
          when "clear"
            buffer_name = raw["buffer_name"].to_s.strip
            AgentCore::ValidationError.raise!(
              "bootstrap prompt-buffer clear requires buffer_name",
              code: "cybros.bootstrap.bootstrap_state.prompt_buffer_buffer_name_blank",
            ) if buffer_name.blank?
            { "op" => "clear", "buffer_name" => buffer_name }
          else
            AgentCore::ValidationError.raise!(
              "bootstrap prompt-buffer op is invalid",
              code: "cybros.bootstrap.bootstrap_state.prompt_buffer_op_invalid",
              details: { op: raw["op"].to_s },
            )
          end
        end
      end
      private_class_method :normalize_prompt_buffer_ops

      def normalize_prompt_buffer_entry(value)
        raw = value.is_a?(Hash) ? value.deep_stringify_keys : {}
        entry_id = raw["id"].to_s.strip
        buffer_name = raw["buffer_name"].to_s.strip
        content = raw["content"].to_s.strip

        AgentCore::ValidationError.raise!(
          "bootstrap prompt-buffer put requires entry.id",
          code: "cybros.bootstrap.bootstrap_state.prompt_buffer_entry_id_blank",
        ) if entry_id.blank?
        AgentCore::ValidationError.raise!(
          "bootstrap prompt-buffer put requires entry.buffer_name",
          code: "cybros.bootstrap.bootstrap_state.prompt_buffer_buffer_name_blank",
        ) if buffer_name.blank?
        AgentCore::ValidationError.raise!(
          "bootstrap prompt-buffer put requires entry.content",
          code: "cybros.bootstrap.bootstrap_state.prompt_buffer_content_blank",
        ) if content.blank?

        {
          "id" => entry_id,
          "buffer_name" => buffer_name,
          "seq" => Integer(raw["seq"], exception: false) || 0,
          "kind" => raw["kind"].to_s.presence || "note",
          "content" => content,
          "priority" => Integer(raw["priority"], exception: false) || 0,
          "estimated_tokens" => Integer(raw["estimated_tokens"], exception: false) || 0,
          "metadata" => normalize_json(raw["metadata"] || {}),
        }
      end
      private_class_method :normalize_prompt_buffer_entry

      def apply_public_settings_patch!(conversation:, patch:)
        return if patch.blank?

        conversation.public_settings = conversation.public_settings.deep_merge(patch)
        conversation.save!
      end
      private_class_method :apply_public_settings_patch!

      def apply_agent_config_patch!(conversation:, patch:)
        return if patch.blank?

        namespace = conversation.agent.config_namespace.to_s
        agent_config = conversation.agent_config.deep_dup
        current_namespace = agent_config[namespace].is_a?(Hash) ? agent_config[namespace] : {}
        agent_config[namespace] = current_namespace.deep_merge(patch)
        conversation.agent_config = agent_config
        conversation.agent_config_schema_fingerprint = conversation.agent.config_schema_fingerprint
        conversation.save!
      end
      private_class_method :apply_agent_config_patch!

      def apply_kv_ops!(lane:, task_node:, operations:)
        Array(operations).each do |operation|
          case operation["op"]
          when "set"
            entry = ::LaneKVEntry.find_or_initialize_by(lane: lane, key: operation["key"])
            entry.value = operation["value"]
            entry.written_by_type = task_node.class.name
            entry.written_by_id = task_node.id
            entry.save!
          when "delete"
            ::LaneKVEntry.where(lane: lane, key: operation["key"]).delete_all
          end
        end
      end
      private_class_method :apply_kv_ops!

      def apply_prompt_buffer_ops!(lane:, operations:)
        Array(operations).each do |operation|
          case operation["op"]
          when "put"
            entry_payload = operation["entry"]
            entry = lane.lane_prompt_buffer_entries.find_or_initialize_by(id: entry_payload["id"])
            entry.buffer_name = entry_payload["buffer_name"]
            entry.seq = entry_payload["seq"]
            entry.kind = entry_payload["kind"]
            entry.content = entry_payload["content"]
            entry.priority = entry_payload["priority"]
            entry.estimated_tokens = entry_payload["estimated_tokens"]
            entry.metadata = entry_payload["metadata"]
            entry.save!
          when "delete"
            lane.lane_prompt_buffer_entries.where(id: operation["entry_id"]).delete_all
          when "clear"
            lane.lane_prompt_buffer_entries.where(buffer_name: operation["buffer_name"]).delete_all
          end
        end
      end
      private_class_method :apply_prompt_buffer_ops!

      def generic_title?(title)
        normalized = title.to_s.strip.downcase
        normalized.blank? || GENERIC_TITLES.include?(normalized)
      end
      private_class_method :generic_title?

      def title_candidate_for(content)
        normalized = content.to_s.strip.gsub(/\s+/, " ")
        return "Conversation" if normalized.blank?

        candidate = normalized
        candidate = candidate.sub(/[[:punct:]\s]+\z/, "")
        candidate = candidate.first(80).strip
        candidate.presence || "Conversation"
      end
      private_class_method :title_candidate_for

      def normalize_json(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), out|
            out[key.to_s] = normalize_json(nested_value)
          end
        when Array
          value.map { |element| normalize_json(element) }
        else
          value
        end
      end
      private_class_method :normalize_json
    end
  end
end
