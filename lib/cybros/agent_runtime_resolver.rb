# frozen_string_literal: true

module Cybros
  module AgentRuntimeResolver
    MAX_CONTEXT_TURNS = 1000

    module_function

    def runtime_for(node:, provider: nil, base_tool_policy: nil, tools_registry: nil, instrumenter: nil)
      conversation = conversation_for(node)

      agent_metadata = agent_metadata_for(conversation)
      policy_profile = Cybros::AgentProfiles.normalize(agent_metadata&.fetch("policy_profile", nil))

      context_turns =
        parse_context_turns(
          agent_metadata&.fetch("context_turns", nil)
        )

      base_tool_policy ||= AgentCore::Resources::Tools::Policy::DenyAll.new
      tool_policy =
        AgentCore::Resources::Tools::Policy::Profiled.new(
          allowed: Cybros::AgentProfiles.allowed_patterns(policy_profile),
          delegate: base_tool_policy,
          tool_groups: nil,
        )

      provider ||= build_provider
      tools_registry ||= build_tools_registry
      instrumenter ||= build_instrumenter

      runtime_kwargs = {
        provider: provider,
        model: ENV.fetch("AGENT_CORE_MODEL", "gpt-4o-mini"),
        fallback_models: parse_fallback_models_env,
        tools_registry: tools_registry,
        tool_policy: tool_policy,
        instrumenter: instrumenter,
      }

      runtime_kwargs[:context_turns] = context_turns if context_turns

      AgentCore::DAG::Runtime.new(**runtime_kwargs)
    end

    def agent_attributes_for(node)
      conversation = conversation_for(node)
      agent_metadata = agent_metadata_for(conversation)

      policy_profile = Cybros::AgentProfiles.normalize(agent_metadata&.fetch("policy_profile", nil))
      key = agent_metadata&.fetch("key", nil).to_s.strip
      key = "main" if key.empty?

      context_turns = parse_context_turns(agent_metadata&.fetch("context_turns", nil))

      attrs = { key: key, policy_profile: policy_profile }
      attrs[:context_turns] = context_turns if context_turns
      attrs
    rescue StandardError
      { key: "main", policy_profile: Cybros::AgentProfiles::DEFAULT_PROFILE }
    end

    def build_tools_registry
      registry = AgentCore::Resources::Tools::Registry.new
      registry.register_many(Cybros::Subagent::Tools.build)
      registry
    end

    def build_provider
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        base_url: ENV["SIMPLE_INFERENCE_BASE_URL"],
        api_key: ENV["SIMPLE_INFERENCE_API_KEY"],
      )
    end
    private_class_method :build_provider

    def build_instrumenter
      AgentCore::Observability::Adapters::ActiveSupportNotificationsInstrumenter.new
    end
    private_class_method :build_instrumenter

    def parse_fallback_models_env
      ENV
        .fetch("AGENT_CORE_FALLBACK_MODELS", "")
        .split(",")
        .map(&:strip)
        .reject(&:empty?)
    rescue StandardError
      []
    end
    private_class_method :parse_fallback_models_env

    def parse_context_turns(value)
      i = Integer(value, exception: false)
      return nil unless i
      return nil if i < 1 || i > MAX_CONTEXT_TURNS

      i
    rescue StandardError
      nil
    end
    private_class_method :parse_context_turns

    def conversation_for(node)
      graph = node.respond_to?(:graph) ? node.graph : nil
      attachable = graph&.attachable
      attachable.is_a?(Conversation) ? attachable : nil
    rescue StandardError
      nil
    end
    private_class_method :conversation_for

    def agent_metadata_for(conversation)
      meta = conversation&.metadata
      return nil unless meta.is_a?(Hash)

      agent = meta["agent"] || meta[:agent]
      agent.is_a?(Hash) ? agent.transform_keys(&:to_s) : nil
    rescue StandardError
      nil
    end
    private_class_method :agent_metadata_for
  end
end

