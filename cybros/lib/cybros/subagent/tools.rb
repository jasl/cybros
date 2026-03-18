require "json"

module Cybros
  module Subagent
    module Tools
      MAX_CONTEXT_TURNS = 1000
      DEFAULT_POLL_LIMIT_TURNS = 10
      MAX_POLL_LIMIT_TURNS = 50
      DEFAULT_WAIT_TIMEOUT_MS = 1_000
      MAX_WAIT_TIMEOUT_MS = 30_000
      STANDARD_DIAGNOSTIC_LEVEL = "standard"
      DEBUG_DIAGNOSTIC_LEVEL = "debug"
      ALLOWED_DIAGNOSTIC_LEVELS = [STANDARD_DIAGNOSTIC_LEVEL, DEBUG_DIAGNOSTIC_LEVEL].freeze

      ALLOWED_AGENT_PROFILES = Cybros::AgentProfiles::PROFILES.keys.freeze

      module_function

      def build
        [
          build_approve_tool,
          build_close_tool,
          build_deny_tool,
          build_interrupt_tool,
          build_poll_tool,
          build_resume_tool,
          build_run_tool,
          build_send_input_tool,
          build_spawn_tool,
          build_wait_tool,
        ]
      end

      def build_spawn_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "subagent_spawn",
          description: "Spawn a subagent.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              name: { type: "string" },
              prompt: { type: "string" },
              agent_profile: { type: "string", enum: ALLOWED_AGENT_PROFILES },
              context_turns: { type: "integer", minimum: 1, maximum: MAX_CONTEXT_TURNS },
              title: { type: "string" },
            },
            required: ["name", "prompt"],
          },
          metadata: { source: :cybros, category: :subagent, permission_class: "delegate" },
        ) do |args, context:|
          enforce_no_nested_spawn!(context)

          name = args.fetch("name").to_s
          prompt = args.fetch("prompt").to_s

          AgentCore::ValidationError.raise!(
            "name is required",
            code: "cybros.subagent_spawn.name_is_required",
          ) if name.strip.empty?

          AgentCore::ValidationError.raise!(
            "prompt is required",
            code: "cybros.subagent_spawn.prompt_is_required",
          ) if prompt.strip.empty?

          parent = parent_conversation_from_context!(context)
          normalized = normalize_name(name)
          agent_key = normalized.empty? ? "subagent" : "subagent:#{normalized}"

          profile =
            if args.key?("agent_profile")
              raw = args.fetch("agent_profile", nil)
              validate_agent_profile!(raw)
              Cybros::AgentProfiles.normalize(raw)
            else
              inherit_agent_profile(parent, context) || Cybros::AgentProfiles::DEFAULT_PROFILE
            end

          context_turns =
            if args.key?("context_turns")
              parse_context_turns!(args.fetch("context_turns", nil))
            else
              inherit_context_turns(parent, context)
            end

          title =
            if args.key?("title")
              args.fetch("title", nil).to_s
            else
              default_title_for(normalized)
            end

          owner_context = owner_context_from_context!(context, code_prefix: "cybros.subagent_spawn")
          thread =
            SubagentThreads::ControlPlane.spawn!(
              parent: owner_context.fetch(:conversation),
              owner_graph: owner_context.fetch(:graph),
              owner_turn: owner_context.fetch(:turn),
              owner_node: owner_context.fetch(:node),
              request: {
                "name" => name,
                "prompt" => prompt,
                "agent_profile" => profile,
                "context_turns" => context_turns,
                "title" => title,
                "diagnostic_level" => STANDARD_DIAGNOSTIC_LEVEL,
              },
            )

          payload = {
            ok: true,
            subagent_id: thread.id,
            agent_key: agent_key,
            agent_profile: profile,
            status: "spawned",
          }

          success_result_with_subagent_payload(payload)
        end
      end
      private_class_method :build_spawn_tool

      def build_poll_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "subagent_poll",
          description: "Poll a subagent.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              subagent_id: { type: "string" },
              limit_turns: { type: "integer", minimum: 1, maximum: MAX_POLL_LIMIT_TURNS, default: DEFAULT_POLL_LIMIT_TURNS },
            },
            required: ["subagent_id"],
          },
          metadata: { source: :cybros, category: :subagent, permission_class: "read" },
        ) do |args, context:|
          subagent_id = parse_subagent_id!(args.fetch("subagent_id", nil), code_prefix: "cybros.subagent_poll")
          parent = parent_conversation_from_context!(context, code_prefix: "cybros.subagent_poll")
          parent_graph_id = context.attributes.dig(:dag, :graph_id).to_s
          parent_graph = DAG::Graph.find_by(id: parent_graph_id) || parent.dag_graph

          limit_turns =
            if args.key?("limit_turns")
              parse_limit_turns!(args.fetch("limit_turns", nil), code_prefix: "cybros.subagent_poll")
            else
              DEFAULT_POLL_LIMIT_TURNS
            end

          payload =
            SubagentThreads::ControlPlane.poll!(
              subagent_id: subagent_id,
              parent: parent,
              parent_graph: parent_graph,
              limit_turns: limit_turns,
              code_prefix: "cybros.subagent_poll",
            )

          success_result_with_subagent_payload(payload)
        end
      end
      private_class_method :build_poll_tool

      def build_run_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "subagent_run",
          description: "Run a subagent.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              name: { type: "string" },
              prompt: { type: "string" },
              agent_profile: { type: "string", enum: ALLOWED_AGENT_PROFILES },
              context_turns: { type: "integer", minimum: 1, maximum: MAX_CONTEXT_TURNS },
              title: { type: "string" },
              limit_turns: { type: "integer", minimum: 1, maximum: MAX_POLL_LIMIT_TURNS, default: DEFAULT_POLL_LIMIT_TURNS },
              diagnostic_level: { type: "string", enum: ALLOWED_DIAGNOSTIC_LEVELS },
            },
            required: ["name", "prompt"],
          },
          metadata: { source: :cybros, category: :subagent, permission_class: "delegate", execution_mode: "parallel_safe" },
        ) do |args, context:|
          enforce_no_nested_spawn!(context, code_prefix: "cybros.subagent_run", tool_name: "subagent_run")

          name = args.fetch("name").to_s
          prompt = args.fetch("prompt").to_s

          AgentCore::ValidationError.raise!(
            "name is required",
            code: "cybros.subagent_run.name_is_required",
          ) if name.strip.empty?

          AgentCore::ValidationError.raise!(
            "prompt is required",
            code: "cybros.subagent_run.prompt_is_required",
          ) if prompt.strip.empty?

          parent = parent_conversation_from_context!(context, code_prefix: "cybros.subagent_run")
          normalized = normalize_name(name)
          agent_key = normalized.empty? ? "subagent" : "subagent:#{normalized}"

          profile =
            if args.key?("agent_profile")
              raw = args.fetch("agent_profile", nil)
              validate_agent_profile!(raw, code_prefix: "cybros.subagent_run")
              Cybros::AgentProfiles.normalize(raw)
            else
              inherit_agent_profile(parent, context) || Cybros::AgentProfiles::DEFAULT_PROFILE
            end

          context_turns =
            if args.key?("context_turns")
              parse_context_turns!(args.fetch("context_turns", nil), code_prefix: "cybros.subagent_run")
            else
              inherit_context_turns(parent, context)
            end

          title =
            if args.key?("title")
              args.fetch("title", nil).to_s
            else
              default_title_for(normalized)
            end

          limit_turns =
            if args.key?("limit_turns")
              parse_limit_turns!(args.fetch("limit_turns", nil), code_prefix: "cybros.subagent_run")
            else
              DEFAULT_POLL_LIMIT_TURNS
            end

          diagnostic_level =
            if args.key?("diagnostic_level")
              parse_diagnostic_level!(args.fetch("diagnostic_level", nil), code_prefix: "cybros.subagent_run")
            else
              STANDARD_DIAGNOSTIC_LEVEL
            end

          owner_context = owner_context_from_context!(context, code_prefix: "cybros.subagent_run")
          payload =
            SubagentThreads::ControlPlane.run!(
              parent: owner_context.fetch(:conversation),
              owner_graph: owner_context.fetch(:graph),
              owner_turn: owner_context.fetch(:turn),
              owner_node: owner_context.fetch(:node),
              request: {
                "name" => name,
                "prompt" => prompt,
                "agent_profile" => profile,
                "context_turns" => context_turns,
                "title" => title,
                "diagnostic_level" => diagnostic_level,
              },
              limit_turns: limit_turns,
            )

          success_result_with_subagent_payload(payload)
        end
      end
      private_class_method :build_run_tool

      def build_wait_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "subagent_wait",
          description: "Wait on a subagent.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              subagent_id: { type: "string" },
              limit_turns: { type: "integer", minimum: 1, maximum: MAX_POLL_LIMIT_TURNS, default: DEFAULT_POLL_LIMIT_TURNS },
              timeout_ms: { type: "integer", minimum: 0, maximum: MAX_WAIT_TIMEOUT_MS, default: DEFAULT_WAIT_TIMEOUT_MS },
            },
            required: ["subagent_id"],
          },
          metadata: { source: :cybros, category: :subagent, permission_class: "read" },
        ) do |args, context:|
          subagent_id = parse_subagent_id!(args.fetch("subagent_id", nil), code_prefix: "cybros.subagent_wait")
          parent = parent_conversation_from_context!(context, code_prefix: "cybros.subagent_wait")
          parent_graph_id = context.attributes.dig(:dag, :graph_id).to_s
          parent_graph = DAG::Graph.find_by(id: parent_graph_id) || parent.dag_graph

          limit_turns =
            if args.key?("limit_turns")
              parse_limit_turns!(args.fetch("limit_turns", nil), code_prefix: "cybros.subagent_wait")
            else
              DEFAULT_POLL_LIMIT_TURNS
            end

          timeout_ms =
            if args.key?("timeout_ms")
              parse_wait_timeout_ms!(args.fetch("timeout_ms", nil), code_prefix: "cybros.subagent_wait")
            else
              DEFAULT_WAIT_TIMEOUT_MS
            end

          payload =
            SubagentThreads::ControlPlane.wait!(
              subagent_id: subagent_id,
              parent: parent,
              parent_graph: parent_graph,
              limit_turns: limit_turns,
              timeout_ms: timeout_ms,
              code_prefix: "cybros.subagent_wait",
            )

          success_result_with_subagent_payload(payload)
        end
      end
      private_class_method :build_wait_tool

      def build_send_input_tool
        build_mutation_tool(
          name: "subagent_send_input",
          description: "Send input.",
          permission_class: "delegate",
          properties: {
            subagent_id: { type: "string" },
            input: { type: "string" },
          },
          required: ["subagent_id", "input"],
        ) do |args, owner_context|
          input = args.fetch("input").to_s

          AgentCore::ValidationError.raise!(
            "input is required",
            code: "cybros.subagent_send_input.input_is_required",
          ) if input.strip.empty?

          SubagentThreads::ControlPlane.send_input!(
            subagent_id: parse_subagent_id!(args.fetch("subagent_id", nil), code_prefix: "cybros.subagent_send_input"),
            parent: owner_context.fetch(:conversation),
            parent_graph: owner_context.fetch(:graph),
            parent_turn: owner_context.fetch(:turn),
            input: input,
            code_prefix: "cybros.subagent_send_input",
          )
        end
      end
      private_class_method :build_send_input_tool

      def build_resume_tool
        build_mutation_tool(
          name: "subagent_resume",
          description: "Resume.",
          permission_class: "delegate",
          properties: { subagent_id: { type: "string" } },
          required: ["subagent_id"],
        ) do |args, owner_context|
          SubagentThreads::ControlPlane.resume!(
            subagent_id: parse_subagent_id!(args.fetch("subagent_id", nil), code_prefix: "cybros.subagent_resume"),
            parent: owner_context.fetch(:conversation),
            parent_graph: owner_context.fetch(:graph),
            parent_turn: owner_context.fetch(:turn),
            code_prefix: "cybros.subagent_resume",
          )
        end
      end
      private_class_method :build_resume_tool

      def build_interrupt_tool
        build_mutation_tool(
          name: "subagent_interrupt",
          description: "Interrupt.",
          permission_class: "delegate",
          properties: { subagent_id: { type: "string" } },
          required: ["subagent_id"],
        ) do |args, owner_context|
          SubagentThreads::ControlPlane.interrupt!(
            subagent_id: parse_subagent_id!(args.fetch("subagent_id", nil), code_prefix: "cybros.subagent_interrupt"),
            parent: owner_context.fetch(:conversation),
            parent_graph: owner_context.fetch(:graph),
            parent_turn: owner_context.fetch(:turn),
            code_prefix: "cybros.subagent_interrupt",
          )
        end
      end
      private_class_method :build_interrupt_tool

      def build_approve_tool
        build_mutation_tool(
          name: "subagent_approve",
          description: "Approve.",
          permission_class: "delegate",
          properties: {
            subagent_id: { type: "string" },
            node_id: { type: "string" },
          },
          required: ["subagent_id", "node_id"],
        ) do |args, owner_context|
          SubagentThreads::ControlPlane.approve!(
            subagent_id: parse_subagent_id!(args.fetch("subagent_id", nil), code_prefix: "cybros.subagent_approve"),
            parent: owner_context.fetch(:conversation),
            parent_graph: owner_context.fetch(:graph),
            parent_turn: owner_context.fetch(:turn),
            node_id: args.fetch("node_id").to_s,
            code_prefix: "cybros.subagent_approve",
          )
        end
      end
      private_class_method :build_approve_tool

      def build_deny_tool
        build_mutation_tool(
          name: "subagent_deny",
          description: "Deny.",
          permission_class: "delegate",
          properties: {
            subagent_id: { type: "string" },
            node_id: { type: "string" },
          },
          required: ["subagent_id", "node_id"],
        ) do |args, owner_context|
          SubagentThreads::ControlPlane.deny!(
            subagent_id: parse_subagent_id!(args.fetch("subagent_id", nil), code_prefix: "cybros.subagent_deny"),
            parent: owner_context.fetch(:conversation),
            parent_graph: owner_context.fetch(:graph),
            parent_turn: owner_context.fetch(:turn),
            node_id: args.fetch("node_id").to_s,
            code_prefix: "cybros.subagent_deny",
          )
        end
      end
      private_class_method :build_deny_tool

      def build_close_tool
        build_mutation_tool(
          name: "subagent_close",
          description: "Close.",
          permission_class: "delegate",
          properties: { subagent_id: { type: "string" } },
          required: ["subagent_id"],
        ) do |args, owner_context|
          SubagentThreads::ControlPlane.close!(
            subagent_id: parse_subagent_id!(args.fetch("subagent_id", nil), code_prefix: "cybros.subagent_close"),
            parent: owner_context.fetch(:conversation),
            parent_graph: owner_context.fetch(:graph),
            parent_turn: owner_context.fetch(:turn),
            code_prefix: "cybros.subagent_close",
          )
        end
      end
      private_class_method :build_close_tool

      def build_mutation_tool(name:, description:, permission_class:, properties:, required:, &block)
        AgentCore::Resources::Tools::Tool.new(
          name: name,
          description: description,
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: properties,
            required: required,
          },
          metadata: { source: :cybros, category: :subagent, permission_class: permission_class },
        ) do |args, context:|
          owner_context = owner_context_from_context!(context, code_prefix: "cybros.#{name}")
          payload = block.call(args, owner_context)
          success_result_with_subagent_payload(payload)
        end
      end
      private_class_method :build_mutation_tool

      def enforce_no_nested_spawn!(context, code_prefix: "cybros.subagent_spawn", tool_name: "subagent_spawn")
        agent_key = context.attributes.dig(:agent, :key).to_s
        return unless agent_key == "subagent" || agent_key.start_with?("subagent:")

        AgentCore::ValidationError.raise!(
          "nested #{tool_name} is not allowed",
          code: "#{code_prefix}.nested_spawn_not_allowed",
          details: { agent_key: agent_key },
        )
      end
      private_class_method :enforce_no_nested_spawn!

      def parent_conversation_from_context!(context, code_prefix: "cybros.subagent_spawn")
        graph_id = context.attributes.dig(:dag, :graph_id).to_s
        node_id = context.attributes.dig(:dag, :node_id).to_s

        AgentCore::ValidationError.raise!(
          "missing dag context (graph_id/node_id)",
          code: "#{code_prefix}.missing_dag_context",
        ) if graph_id.empty? || node_id.empty?

        graph = DAG::Graph.find_by(id: graph_id)
        AgentCore::ValidationError.raise!(
          "parent graph not found",
          code: "#{code_prefix}.parent_graph_not_found",
          details: { graph_id: graph_id },
        ) if graph.nil?

        convo = graph.attachable
        AgentCore::ValidationError.raise!(
          "parent graph attachable is not a Conversation",
          code: "#{code_prefix}.parent_graph_attachable_is_not_a_conversation",
          details: { attachable_class: convo.class.name },
        ) unless convo.is_a?(Conversation)

        convo
      end
      private_class_method :parent_conversation_from_context!

      def owner_context_from_context!(context, code_prefix: "cybros.subagent_spawn")
        conversation = parent_conversation_from_context!(context, code_prefix: code_prefix)
        graph_id = context.attributes.dig(:dag, :graph_id).to_s
        node_id = context.attributes.dig(:dag, :node_id).to_s
        turn_id = context.attributes.dig(:dag, :turn_id).to_s

        graph = DAG::Graph.find_by(id: graph_id)
        node = graph&.nodes&.find_by(id: node_id)
        turn = DAG::Turn.find_by(id: turn_id)

        AgentCore::ValidationError.raise!(
          "parent graph not found",
          code: "#{code_prefix}.parent_graph_not_found",
          details: { graph_id: graph_id },
        ) if graph.nil?

        AgentCore::ValidationError.raise!(
          "parent node not found",
          code: "#{code_prefix}.parent_node_not_found",
          details: { node_id: node_id },
        ) if node.nil?

        AgentCore::ValidationError.raise!(
          "parent turn not found",
          code: "#{code_prefix}.parent_turn_not_found",
          details: { turn_id: turn_id },
        ) if turn.nil?

        {
          conversation: conversation,
          graph: graph,
          node: node,
          turn: turn,
        }
      end
      private_class_method :owner_context_from_context!

      def parse_subagent_id!(value, code_prefix:)
        subagent_id = value.to_s.strip
        AgentCore::ValidationError.raise!(
          "subagent_id is required",
          code: "#{code_prefix}.subagent_id_is_required",
        ) if subagent_id.empty?

        AgentCore::ValidationError.raise!(
          "subagent_id must be a UUID",
          code: "#{code_prefix}.subagent_id_must_be_a_uuid",
          details: { subagent_id: subagent_id },
        ) unless AgentCore::Utils.uuid_like?(subagent_id)

        subagent_id
      end
      private_class_method :parse_subagent_id!

      def normalize_name(name)
        s = name.to_s.strip.downcase
        s = s.gsub(/[^a-z0-9]+/, "_")
        s = s.gsub(/\A_+|_+\z/, "")
        s
      rescue StandardError
        ""
      end
      private_class_method :normalize_name

      def default_title_for(normalized_name)
        normalized_name.empty? ? "subagent" : "subagent:#{normalized_name}"
      end
      private_class_method :default_title_for

      def validate_agent_profile!(value, code_prefix: "cybros.subagent_spawn")
        s = value.to_s
        return if Cybros::AgentProfiles.valid?(s)

        AgentCore::ValidationError.raise!(
          "agent_profile must be one of: #{ALLOWED_AGENT_PROFILES.join(", ")}",
          code: "#{code_prefix}.invalid_agent_profile",
          details: { agent_profile: s },
        )
      end
      private_class_method :validate_agent_profile!

      def inherit_agent_profile_from_parent(parent_conversation)
        meta = parent_conversation.metadata
        agent = meta.is_a?(Hash) ? (meta["agent"] || meta[:agent]) : nil
        raw = agent.is_a?(Hash) ? (agent["agent_profile"] || agent[:agent_profile]) : nil
        s = raw.to_s.strip
        return nil if s.empty?

        return nil unless Cybros::AgentProfiles.valid?(s)

        Cybros::AgentProfiles.normalize(s)
      rescue StandardError
        nil
      end
      private_class_method :inherit_agent_profile_from_parent

      def inherit_agent_profile(parent_conversation, context)
        from_ctx = context.attributes.dig(:agent, :agent_profile).to_s.strip
        if !from_ctx.empty? && Cybros::AgentProfiles.valid?(from_ctx)
          return Cybros::AgentProfiles.normalize(from_ctx)
        end

        inherit_agent_profile_from_parent(parent_conversation)
      rescue StandardError
        inherit_agent_profile_from_parent(parent_conversation)
      end
      private_class_method :inherit_agent_profile

      def inherit_context_turns(parent_conversation, context)
        from_ctx = context.attributes.dig(:agent, :context_turns)
        parsed = Integer(from_ctx, exception: false)
        return parsed if parsed && parsed >= 1 && parsed <= MAX_CONTEXT_TURNS

        meta = parent_conversation.metadata
        agent = meta.is_a?(Hash) ? (meta["agent"] || meta[:agent]) : nil
        raw = agent.is_a?(Hash) ? (agent["context_turns"] || agent[:context_turns]) : nil

        parsed = Integer(raw, exception: false)
        return parsed if parsed && parsed >= 1 && parsed <= MAX_CONTEXT_TURNS

        DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS
      rescue StandardError
        DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS
      end
      private_class_method :inherit_context_turns

      def parse_context_turns!(value, code_prefix: "cybros.subagent_spawn")
        i = Integer(value, exception: false)
        AgentCore::ValidationError.raise!(
          "context_turns must be an Integer",
          code: "#{code_prefix}.context_turns_must_be_an_integer",
          details: { value_class: value.class.name },
        ) unless i

        AgentCore::ValidationError.raise!(
          "context_turns must be between 1 and #{MAX_CONTEXT_TURNS}",
          code: "#{code_prefix}.context_turns_out_of_range",
          details: { context_turns: i },
        ) if i < 1 || i > MAX_CONTEXT_TURNS

        i
      end
      private_class_method :parse_context_turns!

      def parse_limit_turns!(value, code_prefix:)
        i = Integer(value, exception: false)
        AgentCore::ValidationError.raise!(
          "limit_turns must be an Integer",
          code: "#{code_prefix}.limit_turns_must_be_an_integer",
          details: { value_class: value.class.name },
        ) unless i

        AgentCore::ValidationError.raise!(
          "limit_turns must be between 1 and #{MAX_POLL_LIMIT_TURNS}",
          code: "#{code_prefix}.limit_turns_out_of_range",
          details: { limit_turns: i },
        ) if i < 1 || i > MAX_POLL_LIMIT_TURNS

        i
      end
      private_class_method :parse_limit_turns!

      def parse_wait_timeout_ms!(value, code_prefix:)
        i = Integer(value, exception: false)
        AgentCore::ValidationError.raise!(
          "timeout_ms must be an Integer",
          code: "#{code_prefix}.timeout_ms_must_be_an_integer",
          details: { value_class: value.class.name },
        ) unless i

        AgentCore::ValidationError.raise!(
          "timeout_ms must be between 0 and #{MAX_WAIT_TIMEOUT_MS}",
          code: "#{code_prefix}.timeout_ms_out_of_range",
          details: { timeout_ms: i },
        ) if i.negative? || i > MAX_WAIT_TIMEOUT_MS

        i
      end
      private_class_method :parse_wait_timeout_ms!

      def parse_diagnostic_level!(value, code_prefix:)
        level = value.to_s
        return level if ALLOWED_DIAGNOSTIC_LEVELS.include?(level)

        AgentCore::ValidationError.raise!(
          "diagnostic_level must be one of: #{ALLOWED_DIAGNOSTIC_LEVELS.join(", ")}",
          code: "#{code_prefix}.diagnostic_level_invalid",
          details: { diagnostic_level: level },
        )
      end
      private_class_method :parse_diagnostic_level!

      def success_result_with_subagent_payload(payload)
        normalized = AgentCore::Utils.deep_stringify_keys(payload)
        AgentCore::Resources::Tools::ToolResult.success(text: JSON.generate(normalized), metadata: { subagent: normalized })
      end
      private_class_method :success_result_with_subagent_payload
    end
  end
end
