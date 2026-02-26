# frozen_string_literal: true

module Cybros
  module AgentRuntimeResolver
    MAX_CONTEXT_TURNS = 1000

    module_function

    def phase_0_tool_policy(base_tool_policy: AgentCore::Resources::Tools::Policy::ConfirmAll.new)
      AgentCore::Resources::Tools::Policy::Ruleset.new(
        allow: [
          { tools: ["memory_*"], reason: "phase_0_auto_allow_memory_tools" },
          { tools: ["skills_*"], reason: "phase_0_auto_allow_skills_tools" },
        ],
        delegate: base_tool_policy,
        tool_groups: nil,
      )
    end

    def channel_for(node:)
      from_node = routing_channel_from_metadata(node&.metadata)
      return from_node if from_node

      conversation = conversation_for(node)
      from_conversation = routing_channel_from_metadata(conversation&.metadata)
      return from_conversation if from_conversation

      nil
    rescue StandardError
      nil
    end

    def runtime_for(node:, provider: nil, base_tool_policy: nil, tools_registry: nil, instrumenter: nil)
      conversation = conversation_for(node)

      agent_metadata = agent_metadata_for(conversation)
      model_resolution = resolve_model_and_provider(agent_metadata)
      profile_resolution = resolve_profile(agent_metadata)
      profile_name = profile_resolution.fetch(:profile_name)
      definition = profile_resolution.fetch(:definition)
      profile_config = profile_resolution.fetch(:profile_config)

      context_turns =
        if profile_config&.context_turns
          profile_config.context_turns
        else
          parse_context_turns(agent_metadata&.fetch("context_turns", nil))
        end

      base_tool_policy ||= AgentCore::Resources::Tools::Policy::ConfirmAll.new

      delegate =
        if profile_config&.tools_allowed
          AgentCore::Resources::Tools::Policy::Profiled.new(
            allowed: profile_config.tools_allowed,
            delegate: base_tool_policy,
            tool_groups: nil,
          )
        else
          base_tool_policy
        end

      tool_policy =
        phase_0_tool_policy(
          base_tool_policy:
            AgentCore::Resources::Tools::Policy::Profiled.new(
              allowed: Array(definition.fetch(:tool_patterns)),
              delegate: delegate,
              tool_groups: nil,
            ),
        )

      provider ||= model_resolution.fetch(:provider)
      tools_registry ||= build_tools_registry
      instrumenter ||= build_instrumenter

      prompt_injection_sources =
        AgentCore::Resources::PromptInjections::Factory.build_sources(
          specs: definition.fetch(:prompt_injections, []),
          text_store: nil,
        )

      runtime_kwargs = {
        provider: provider,
        model: model_resolution.fetch(:model),
        fallback_models: parse_fallback_models_env,
        tools_registry: tools_registry,
        tool_policy: tool_policy,
        instrumenter: instrumenter,
        prompt_mode: definition.fetch(:prompt_mode, :full),
        memory_search_limit: definition.fetch(:memory_search_limit) { Cybros::AgentProfiles::DEFAULT_MEMORY_SEARCH_LIMIT },
        prompt_injection_sources: prompt_injection_sources,
        include_skill_locations: definition.fetch(:include_skill_locations, false),
        directives_config: definition.fetch(:directives_config, nil),
        system_prompt_section_overrides: definition.fetch(:system_prompt_section_overrides, {}),
      }

      runtime_kwargs[:context_turns] = context_turns if context_turns

      agent_key = agent_metadata&.fetch("key", nil).to_s.strip
      agent_key = "main" if agent_key.empty?

      agent_attrs = { key: agent_key, agent_profile: profile_name }
      agent_attrs[:context_turns] = context_turns if context_turns

      workspace_dir =
        if defined?(Rails) && Rails.respond_to?(:root)
          Rails.root.to_s
        else
          Dir.pwd
        end
      workspace_dir = Dir.pwd if workspace_dir.to_s.strip.empty?

      ctx_attrs = {
        cwd: workspace_dir,
        workspace_dir: workspace_dir,
        agent: agent_attrs,
      }
      if (channel = channel_for(node: node))
        ctx_attrs[:channel] = channel
      end
      runtime_kwargs[:execution_context_attributes] = ctx_attrs

      AgentCore::DAG::Runtime.new(**runtime_kwargs)
    end

    def build_tools_registry
      registry = AgentCore::Resources::Tools::Registry.new
      registry.register_many(Cybros::Subagent::Tools.build)

      # Phase 0: always register native memory + skills tools.
      begin
        skills_dir = Rails.root.join("skills")
        if skills_dir.directory?
          registry.register_skills_store(
            AgentCore::Resources::Skills::FileSystemStore.new(dirs: [skills_dir.to_s], strict: false)
          )
        end
      rescue StandardError
        # ignore
      end

      begin
        registry.register_memory_store(build_memory_store)
      rescue StandardError
        # ignore
      end

      registry
    end

    def resolve_model_and_provider(agent_metadata)
      default_model = ENV.fetch("AGENT_CORE_MODEL", "gpt-4o-mini").to_s.strip
      default_model = "gpt-4o-mini" if default_model.empty?

      prefer = model_prefer_from_agent_metadata(agent_metadata)
      prefer = [default_model] if prefer.empty?

      provider = nil
      chosen_model = nil

      providers = fetch_llm_providers

      prefer.each do |model|
        matching = providers.select { |p| Array(p.model_allowlist).include?(model) }
        next if matching.empty?

        provider = matching.max_by { |p| p.priority.to_i }
        chosen_model = model
        break
      end

      if provider.nil?
        provider = providers.max_by { |p| p.priority.to_i } if providers.any?
      end

      if chosen_model.nil?
        allowlist = Array(provider&.model_allowlist).map(&:to_s).reject(&:blank?)
        chosen_model =
          if allowlist.include?(default_model)
            default_model
          else
            allowlist.first || default_model
          end
      end

      { provider: build_provider_from_record(provider) || build_default_provider, model: chosen_model }
    rescue StandardError
      { provider: build_default_provider, model: default_model }
    end
    private_class_method :resolve_model_and_provider

    def fetch_llm_providers
      return [] unless defined?(LLMProvider)

      LLMProvider.order(priority: :desc).to_a
    rescue StandardError
      []
    end
    private_class_method :fetch_llm_providers

    def model_prefer_from_agent_metadata(agent_metadata)
      return [] unless agent_metadata.is_a?(Hash)

      agent_program = agent_metadata.fetch("agent_program", nil)
      agent_program = agent_program.is_a?(Hash) ? agent_program : {}

      prefer = agent_program.fetch("model_prefer", nil) || agent_program.fetch("model", nil)
      prefer = prefer.fetch("prefer", nil) if prefer.is_a?(Hash)

      Array(prefer).map { |v| v.to_s.strip }.reject(&:empty?).uniq
    rescue StandardError
      []
    end
    private_class_method :model_prefer_from_agent_metadata

    def build_provider_from_record(record)
      return nil unless record

      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        base_url: record.base_url,
        api_key: record.api_key.presence,
        headers: record.headers || {},
      )
    rescue StandardError
      nil
    end
    private_class_method :build_provider_from_record

    def build_default_provider
      AgentCore::Resources::Provider::SimpleInferenceProvider.new(
        base_url: ENV["SIMPLE_INFERENCE_BASE_URL"],
        api_key: ENV["SIMPLE_INFERENCE_API_KEY"],
      )
    end
    private_class_method :build_default_provider

    def build_memory_store
      if Rails.env.test?
        embedder =
          Class.new do
            def embed(text:)
              _ = text
              Array.new(1536, 0.0)
            end
          end.new

        return AgentCore::Resources::Memory::PgvectorStore.new(embedder: embedder, conversation_id: nil, include_global: true)
      end

      embed_model = ENV.fetch("AGENT_CORE_EMBEDDING_MODEL", "text-embedding-3-small").to_s.strip
      embed_model = "text-embedding-3-small" if embed_model.empty?

      embedder =
        AgentCore::Resources::Memory::Embedder::SimpleInference.new(
          model: embed_model,
          base_url: ENV["SIMPLE_INFERENCE_BASE_URL"],
          api_key: ENV["SIMPLE_INFERENCE_API_KEY"],
        )

      AgentCore::Resources::Memory::PgvectorStore.new(embedder: embedder, conversation_id: nil, include_global: true)
    rescue StandardError
      AgentCore::Resources::Memory::InMemory.new
    end
    private_class_method :build_memory_store

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
      return nil if value.nil?

      stripped = value.to_s.strip
      return nil if stripped.empty?

      i = Integer(stripped, exception: false)
      AgentCore::ValidationError.raise!(
        "context_turns must be an Integer",
        code: "cybros.agent_runtime_resolver.context_turns_must_be_an_integer",
        details: { value_class: value.class.name },
      ) unless i

      if i < 1 || i > MAX_CONTEXT_TURNS
        AgentCore::ValidationError.raise!(
          "context_turns must be between 1 and #{MAX_CONTEXT_TURNS}",
          code: "cybros.agent_runtime_resolver.context_turns_out_of_range",
          details: { context_turns: i },
        )
      end

      i
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

    def routing_channel_from_metadata(metadata)
      return nil unless metadata.is_a?(Hash)

      routing = metadata["routing"] || metadata[:routing]
      return nil unless routing.is_a?(Hash)

      channel = routing["channel"] || routing[:channel]
      channel = channel.to_s.lines.first.to_s.strip
      return nil if channel.empty?

      channel
    rescue StandardError
      nil
    end
    private_class_method :routing_channel_from_metadata

    def resolve_profile(agent_metadata)
      raw = agent_metadata.is_a?(Hash) ? agent_metadata.fetch("agent_profile", nil) : nil

      profile_config =
        if raw.is_a?(Hash) || (raw.is_a?(String) && raw.lstrip.start_with?("{"))
          Cybros::AgentProfileConfig.from_value(raw)
        end

      profile_name = profile_config ? profile_config.base_profile : normalize_profile_name!(raw)

      definition = Cybros::AgentProfiles.definition(profile_name)
      if profile_config
        definition = profile_config.apply_overrides(definition)
      end

      { profile_name: profile_name, definition: definition, profile_config: profile_config }
    end
    private_class_method :resolve_profile

    def normalize_profile_name!(value)
      return Cybros::AgentProfiles::DEFAULT_PROFILE if value.nil?

      unless value.is_a?(String)
        AgentCore::ValidationError.raise!(
          "agent_profile must be a String or object",
          code: "cybros.agent_runtime_resolver.agent_profile_must_be_a_string_or_object",
          details: { value_class: value.class.name },
        )
      end

      s = value.to_s.strip.downcase
      return Cybros::AgentProfiles::DEFAULT_PROFILE if s.empty?

      return s if Cybros::AgentProfiles.valid?(s)

      AgentCore::ValidationError.raise!(
        "agent_profile must be one of: #{Cybros::AgentProfiles::PROFILES.keys.sort.join(", ")}",
        code: "cybros.agent_runtime_resolver.agent_profile_must_be_one_of",
        details: { agent_profile: s },
      )
    end
    private_class_method :normalize_profile_name!
  end
end
