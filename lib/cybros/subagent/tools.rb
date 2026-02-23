# frozen_string_literal: true

require "json"
require "securerandom"

module Cybros
  module Subagent
    module Tools
      MAX_CONTEXT_TURNS = 1000
      DEFAULT_POLL_LIMIT_TURNS = 10
      MAX_POLL_LIMIT_TURNS = 50

      ALLOWED_POLICY_PROFILES = Cybros::AgentProfiles::PROFILES.keys.freeze

      module_function

      def build
        [build_spawn_tool, build_poll_tool]
      end

      def build_spawn_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "subagent_spawn",
          description: "Spawn a subagent as an independent conversation and start it with a prompt.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              name: { type: "string", description: "Subagent name (used for metadata and default title)." },
              prompt: { type: "string", description: "Initial user prompt for the subagent." },
              policy_profile: { type: "string", enum: ALLOWED_POLICY_PROFILES },
              context_turns: { type: "integer", minimum: 1, maximum: MAX_CONTEXT_TURNS },
              title: { type: "string", description: "Optional child conversation title." },
            },
            required: ["name", "prompt"],
          },
          metadata: { source: :cybros, category: :subagent },
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
          parent_graph_id = context.attributes.dig(:dag, :graph_id).to_s
          spawned_from_node_id = context.attributes.dig(:dag, :node_id).to_s

          normalized = normalize_name(name)
          agent_key = normalized.empty? ? "subagent" : "subagent:#{normalized}"

          policy_profile =
            if args.key?("policy_profile")
              raw = args.fetch("policy_profile", nil)
              validate_policy_profile!(raw)
              raw.to_s
            else
              inherit_policy_profile(parent) || "full"
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

          child = nil

          Conversation.transaction do
            child =
              Conversation.create!(
                title: title,
                metadata: build_child_metadata(
                  agent_key: agent_key,
                  policy_profile: policy_profile,
                  context_turns: context_turns,
                  name: name,
                  parent_conversation_id: parent.id.to_s,
                  parent_graph_id: parent_graph_id,
                  spawned_from_node_id: spawned_from_node_id,
                ),
              )

            seed_child_graph!(child, initial_prompt: prompt)
          end

          payload = {
            ok: true,
            child_conversation_id: child.id.to_s,
            child_graph_id: child.dag_graph.id.to_s,
            agent_key: agent_key,
            policy_profile: policy_profile,
            status: "spawned",
          }

          AgentCore::Resources::Tools::ToolResult.success(
            text: JSON.generate(payload),
            metadata: { subagent: payload },
          )
        end
      end
      private_class_method :build_spawn_tool

      def build_poll_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "subagent_poll",
          description: "Poll a subagent conversation for status and a bounded transcript preview.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              child_conversation_id: { type: "string" },
              limit_turns: { type: "integer", minimum: 1, maximum: MAX_POLL_LIMIT_TURNS, default: DEFAULT_POLL_LIMIT_TURNS },
            },
            required: ["child_conversation_id"],
          },
          metadata: { source: :cybros, category: :subagent },
        ) do |args, **|
          child_id = args.fetch("child_conversation_id").to_s.strip
          AgentCore::ValidationError.raise!(
            "child_conversation_id is required",
            code: "cybros.subagent_poll.child_conversation_id_is_required",
          ) if child_id.empty?

          limit_turns = Integer(args.fetch("limit_turns", DEFAULT_POLL_LIMIT_TURNS), exception: false) || DEFAULT_POLL_LIMIT_TURNS
          AgentCore::ValidationError.raise!(
            "limit_turns must be between 1 and #{MAX_POLL_LIMIT_TURNS}",
            code: "cybros.subagent_poll.limit_turns_out_of_range",
            details: { limit_turns: limit_turns },
          ) if limit_turns < 1 || limit_turns > MAX_POLL_LIMIT_TURNS

          child = Conversation.find_by(id: child_id)
          if child.nil?
            payload = {
              ok: true,
              child_conversation_id: child_id,
              child_graph_id: nil,
              status: "missing",
              counts: { pending: 0, running: 0, awaiting_approval: 0 },
              leaf: nil,
              transcript_lines: [],
            }

            AgentCore::Resources::Tools::ToolResult.success(text: JSON.generate(payload), metadata: { subagent: payload })
          else
            graph = child.dag_graph
            counts = node_state_counts(graph)
            status = status_for_counts(counts)
            leaf = leaf_for_main_lane(graph)

            transcript_lines = transcript_lines_for(graph, limit_turns: limit_turns)

            payload = {
              ok: true,
              child_conversation_id: child.id.to_s,
              child_graph_id: graph.id.to_s,
              status: status,
              counts: counts,
              leaf: leaf,
              transcript_lines: transcript_lines,
            }

            AgentCore::Resources::Tools::ToolResult.success(text: JSON.generate(payload), metadata: { subagent: payload })
          end
        end
      end
      private_class_method :build_poll_tool

      def enforce_no_nested_spawn!(context)
        agent_key = context.attributes.dig(:agent, :key).to_s
        return unless agent_key.start_with?("subagent:")

        AgentCore::ValidationError.raise!(
          "nested subagent_spawn is not allowed",
          code: "cybros.subagent_spawn.nested_spawn_not_allowed",
          details: { agent_key: agent_key },
        )
      end
      private_class_method :enforce_no_nested_spawn!

      def parent_conversation_from_context!(context)
        graph_id = context.attributes.dig(:dag, :graph_id).to_s
        node_id = context.attributes.dig(:dag, :node_id).to_s

        AgentCore::ValidationError.raise!(
          "missing dag context (graph_id/node_id)",
          code: "cybros.subagent_spawn.missing_dag_context",
        ) if graph_id.empty? || node_id.empty?

        graph = DAG::Graph.find_by(id: graph_id)
        AgentCore::ValidationError.raise!(
          "parent graph not found",
          code: "cybros.subagent_spawn.parent_graph_not_found",
          details: { graph_id: graph_id },
        ) if graph.nil?

        convo = graph.attachable
        AgentCore::ValidationError.raise!(
          "parent graph attachable is not a Conversation",
          code: "cybros.subagent_spawn.parent_graph_attachable_is_not_a_conversation",
          details: { attachable_class: convo.class.name },
        ) unless convo.is_a?(Conversation)

        convo
      end
      private_class_method :parent_conversation_from_context!

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

      def validate_policy_profile!(value)
        s = value.to_s
        return if Cybros::AgentProfiles.valid?(s)

        AgentCore::ValidationError.raise!(
          "policy_profile must be one of: #{ALLOWED_POLICY_PROFILES.join(", ")}",
          code: "cybros.subagent_spawn.invalid_policy_profile",
          details: { policy_profile: s },
        )
      end
      private_class_method :validate_policy_profile!

      def inherit_policy_profile(parent_conversation)
        meta = parent_conversation.metadata
        agent = meta.is_a?(Hash) ? (meta["agent"] || meta[:agent]) : nil
        raw = agent.is_a?(Hash) ? (agent["policy_profile"] || agent[:policy_profile]) : nil
        s = raw.to_s.strip
        return nil if s.empty?

        Cybros::AgentProfiles.normalize(s)
      rescue StandardError
        nil
      end
      private_class_method :inherit_policy_profile

      def inherit_context_turns(parent_conversation, context)
        from_ctx = context.attributes.dig(:agent, :context_turns)
        parsed = Integer(from_ctx, exception: false)
        return parsed if parsed && parsed >= 1 && parsed <= MAX_CONTEXT_TURNS

        meta = parent_conversation.metadata
        agent = meta.is_a?(Hash) ? (meta["agent"] || meta[:agent]) : nil
        raw = agent.is_a?(Hash) ? (agent["context_turns"] || agent[:context_turns]) : nil

        parsed = Integer(raw, exception: false)
        return parsed if parsed && parsed >= 1 && parsed <= MAX_CONTEXT_TURNS

        AgentCore::DAG::Runtime::DEFAULT_CONTEXT_TURNS
      rescue StandardError
        AgentCore::DAG::Runtime::DEFAULT_CONTEXT_TURNS
      end
      private_class_method :inherit_context_turns

      def parse_context_turns!(value)
        i = Integer(value, exception: false)
        AgentCore::ValidationError.raise!(
          "context_turns must be an Integer",
          code: "cybros.subagent_spawn.context_turns_must_be_an_integer",
          details: { value_class: value.class.name },
        ) unless i

        AgentCore::ValidationError.raise!(
          "context_turns must be between 1 and #{MAX_CONTEXT_TURNS}",
          code: "cybros.subagent_spawn.context_turns_out_of_range",
          details: { context_turns: i },
        ) if i < 1 || i > MAX_CONTEXT_TURNS

        i
      end
      private_class_method :parse_context_turns!

      def build_child_metadata(
        agent_key:,
        policy_profile:,
        context_turns:,
        name:,
        parent_conversation_id:,
        parent_graph_id:,
        spawned_from_node_id:
      )
        {
          "agent" => {
            "key" => agent_key,
            "policy_profile" => policy_profile,
            "context_turns" => context_turns,
          },
          "subagent" => {
            "name" => name,
            "parent_conversation_id" => parent_conversation_id,
            "parent_graph_id" => parent_graph_id,
            "spawned_from_node_id" => spawned_from_node_id,
          },
        }
      end
      private_class_method :build_child_metadata

      def seed_child_graph!(conversation, initial_prompt:)
        graph = conversation.dag_graph
        turn_id = generate_uuidv7(graph)

        graph.mutate!(turn_id: turn_id) do |m|
          developer =
            m.create_node(
              node_type: Messages::DeveloperMessage.node_type_key,
              state: DAG::Node::FINISHED,
              content: "You are a subagent running in an independent conversation.",
              metadata: { "transcript_visible" => false },
            )

          user =
            m.create_node(
              node_type: Messages::UserMessage.node_type_key,
              state: DAG::Node::FINISHED,
              content: initial_prompt,
              metadata: {},
            )

          agent =
            m.create_node(
              node_type: Messages::AgentMessage.node_type_key,
              state: DAG::Node::PENDING,
              metadata: {},
            )

          m.create_edge(from_node: developer, to_node: user, edge_type: DAG::Edge::SEQUENCE)
          m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
        end
      end
      private_class_method :seed_child_graph!

      def generate_uuidv7(graph)
        _ = graph
        ActiveRecord::Base.connection.select_value("select uuidv7()")
      rescue StandardError
        SecureRandom.uuid
      end
      private_class_method :generate_uuidv7

      def node_state_counts(graph)
        rows =
          graph
            .nodes
            .active
            .where(state: [DAG::Node::PENDING, DAG::Node::RUNNING, DAG::Node::AWAITING_APPROVAL])
            .group(:state)
            .count

        {
          pending: rows.fetch(DAG::Node::PENDING, 0),
          running: rows.fetch(DAG::Node::RUNNING, 0),
          awaiting_approval: rows.fetch(DAG::Node::AWAITING_APPROVAL, 0),
        }
      rescue StandardError
        { pending: 0, running: 0, awaiting_approval: 0 }
      end
      private_class_method :node_state_counts

      def status_for_counts(counts)
        running = counts.fetch(:running, 0).to_i
        awaiting_approval = counts.fetch(:awaiting_approval, 0).to_i
        pending = counts.fetch(:pending, 0).to_i

        return "running" if running.positive?
        return "awaiting_approval" if awaiting_approval.positive?
        return "pending" if pending.positive?

        "idle"
      rescue StandardError
        "idle"
      end
      private_class_method :status_for_counts

      def leaf_for_main_lane(graph)
        lane = graph.main_lane
        leaf = graph.leaf_nodes.where(lane_id: lane.id).order(:id).last
        return nil if leaf.nil?

        { node_id: leaf.id.to_s, state: leaf.state.to_s }
      rescue StandardError
        nil
      end
      private_class_method :leaf_for_main_lane

      def transcript_lines_for(graph, limit_turns:)
        lane = graph.main_lane
        transcript = lane.transcript_recent_turns(limit_turns: limit_turns, mode: :preview, include_deleted: false)

        Array(transcript).filter_map do |node|
          node_type = node.fetch("node_type", "").to_s
          payload = node.fetch("payload", {})
          payload = {} unless payload.is_a?(Hash)
          input = payload.fetch("input", {})
          input = {} unless input.is_a?(Hash)
          output_preview = payload.fetch("output_preview", {})
          output_preview = {} unless output_preview.is_a?(Hash)

          case node_type
          when "user_message"
            "U:#{input.fetch('content', '').to_s}"
          when "agent_message", "character_message"
            "A:#{output_preview.fetch('content', '').to_s}"
          else
            nil
          end
        end
      rescue StandardError
        []
      end
      private_class_method :transcript_lines_for
    end
  end
end
