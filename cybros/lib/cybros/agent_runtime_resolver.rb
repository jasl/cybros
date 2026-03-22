module Cybros
  module AgentRuntimeResolver
    require "shellwords"
    require_relative "llm/catalog"
    require_relative "llm/capability_gated_provider"
    require_relative "llm/codex_oauth"
    require_relative "bootstrap/tools"
    require_relative "attachments/tools"
    require_relative "agent_owned_tools"
    require_relative "context_budget/default_policy"
    require_relative "context_budget/tools"
    require_relative "lane_processes/tools"
    require_relative "programmable_agent"
    require_relative "programmable_agent_provider"

    MAX_CONTEXT_TURNS = 1000
    PROTECTED_AGENT_ROOT_CONFIRM_REASON = "protected_agent_root_write".freeze
    PROTECTED_AGENT_ROOT_DENY_REASON = "protected_agent_root_read_only".freeze
    PROTECTED_AGENT_ROOT_EXEC_DENY_REASON = "protected_agent_root_exec_mutation".freeze

    class ProtectedAgentPathPolicy < AgentCore::Resources::Tools::Policy::Base
      def initialize(delegate:)
        @delegate = delegate
      end

      def filter(tools:, context:)
        @delegate.filter(tools: tools, context: context)
      end

      def authorize(name:, arguments:, context:)
        decision = @delegate.authorize(name: name, arguments: arguments, context: context)
        return decision if decision.denied?

        classification = ProtectedAgentPathClassifier.call(name: name, arguments: arguments, context: context)

        case classification.fetch(:action)
        when :confirm
          return decision if decision.requires_confirmation?

          AgentCore::Resources::Tools::Policy::Decision.confirm(
            reason: PROTECTED_AGENT_ROOT_CONFIRM_REASON,
            required: decision.required == true,
            deny_effect: decision.deny_effect,
          )
        when :deny
          AgentCore::Resources::Tools::Policy::Decision.deny(reason: classification.fetch(:reason))
        else
          decision
        end
      end
    end

    module ProtectedAgentPathClassifier
      module_function

      CODEX_MUTATION_PREFIXES = ["*** Update File: ", "*** Add File: ", "*** Delete File: "].freeze
      UNIFIED_PATCH_PREFIXES = ["--- ", "+++ "].freeze
      SHELL_MUTATION_PATTERNS = [
        /(^|[^<])>>?/,
        /\|\s*tee\b/,
        /\b(?:cp|mv|rm|touch|install|truncate|mkdir)\b/,
        /\bsed\s+-i\b/,
      ].freeze

      def call(name:, arguments:, context:)
        workspace = workspace_payload_for(context)
        return { action: nil } unless workspace

        case name.to_s
        when "skills_install"
          { action: :confirm }
        when "write", "edit"
          classify_paths([resolve_relative_path(arguments["path"], workspace)].compact, workspace: workspace)
        when "apply_patch"
          classify_paths(patch_target_paths(arguments["patch"], workspace), workspace: workspace)
        when "exec"
          if protected_exec_mutation?(command: arguments["command"], workspace: workspace)
            { action: :deny, reason: PROTECTED_AGENT_ROOT_EXEC_DENY_REASON }
          else
            { action: nil }
          end
        else
          { action: nil }
        end
      end

      def classify_paths(paths, workspace:)
        confirm = false

        Array(paths).each do |path|
          case protected_path_rule(path, workspace)
          when :deny
            return { action: :deny, reason: PROTECTED_AGENT_ROOT_DENY_REASON }
          when :confirm
            confirm = true
          end
        end

        confirm ? { action: :confirm } : { action: nil }
      end
      private_class_method :classify_paths

      def protected_exec_mutation?(command:, workspace:)
        raw = command.to_s
        return false if raw.blank?
        return false unless SHELL_MUTATION_PATTERNS.any? { |pattern| raw.match?(pattern) }

        shell_path_candidates(raw).any? do |candidate|
          path = resolve_relative_path(candidate, workspace)
          path && protected_path_rule(path, workspace).present?
        end
      end
      private_class_method :protected_exec_mutation?

      def shell_path_candidates(command)
        redirection_targets = command.to_s.scan(/(?:^|\s)(?:\d*>>?|\d*>\>|&>>|&>)\s*([^\s;|&]+)/).flatten
        Shellwords.shellsplit(command.to_s).filter_map do |token|
          cleaned = normalize_shell_token(token)
          next if cleaned.empty?
          next unless cleaned.include?(File::SEPARATOR) || cleaned.start_with?(".") || %w[SOUL.md USER.md AGENTS.md].include?(cleaned)

          cleaned
        end.uniq
      rescue ArgumentError
        redirection_targets.map { |token| normalize_shell_token(token) }.reject(&:blank?).uniq
      end
      private_class_method :shell_path_candidates

      def normalize_shell_token(token)
        token.to_s.strip.gsub(/\A['"]|['"]\z/, "").sub(/[;|&]+\z/, "")
      end
      private_class_method :normalize_shell_token

      def patch_target_paths(patch_text, workspace)
        raw_paths =
          if patch_text.to_s.lstrip.start_with?("*** Begin Patch")
            codex_patch_paths(patch_text)
          else
            unified_patch_paths(patch_text)
          end

        raw_paths.filter_map { |path| resolve_relative_path(path, workspace) }
      end
      private_class_method :patch_target_paths

      def codex_patch_paths(patch_text)
        patch_text.to_s.each_line.filter_map do |line|
          prefix = CODEX_MUTATION_PREFIXES.find { |value| line.start_with?(value) }
          next unless prefix

          line.delete_prefix(prefix).strip.presence
        end.uniq
      end
      private_class_method :codex_patch_paths

      def unified_patch_paths(patch_text)
        patch_text.to_s.each_line.filter_map do |line|
          next unless line.start_with?(*UNIFIED_PATCH_PREFIXES)

          raw_path = line.split(/\s+/, 2).last.to_s.split("\t", 2).first.to_s.strip
          next if raw_path.blank? || raw_path == "/dev/null"

          normalized = raw_path.start_with?("a/", "b/") ? raw_path[2..] : raw_path
          normalized.presence
        end.uniq
      end
      private_class_method :unified_patch_paths

      def workspace_payload_for(context)
        attributes = context.attributes if context.respond_to?(:attributes)
        return nil unless attributes.is_a?(Hash)

        cybros = attributes[:cybros]
        cybros = AgentCore::Utils.deep_stringify_keys(cybros) if cybros.is_a?(Hash)
        return nil unless cybros.is_a?(Hash)
        workspace = cybros&.dig("execution_context", "workspace")
        return nil unless workspace.is_a?(Hash)

        root_path = workspace.fetch("root_path", "").to_s.strip
        cwd = workspace.fetch("cwd", "").to_s.strip
        return nil if root_path.empty? || cwd.empty?

        normalized_root = Pathname.new(root_path).expand_path
        normalized_cwd = normalize_workspace_path(cwd, root_path: normalized_root)
        return nil if normalized_cwd.nil?

        {
          root_path: normalized_root,
          cwd: normalized_cwd,
          conversation_path: normalize_workspace_path(workspace.fetch("conversation_path", ""), root_path: normalized_root),
          lane_path: normalize_workspace_path(workspace.fetch("lane_path", ""), root_path: normalized_root),
        }
      end
      private_class_method :workspace_payload_for

      def normalize_workspace_path(raw_path, root_path:)
        path = raw_path.to_s.strip
        return nil if path.empty?

        expanded = Pathname.new(path).expand_path
        ensure_within_root!(expanded, root_path)
        expanded
      rescue SecurityError
        nil
      end
      private_class_method :normalize_workspace_path

      def resolve_relative_path(raw_path, workspace)
        path = raw_path.to_s.strip
        return nil if path.empty? || path.start_with?("/", "~")

        expanded = workspace.fetch(:cwd).join(path).expand_path
        ensure_within_root!(expanded, workspace.fetch(:root_path))
        expanded
      rescue SecurityError
        nil
      end
      private_class_method :resolve_relative_path

      def protected_path_rule(path, workspace)
        root_path = workspace.fetch(:root_path)
        relative = path.relative_path_from(root_path).to_s
        return :deny if relative == "AGENTS.md" || relative.start_with?(".history/")
        return :confirm if env_overlay_path_for?(relative, root_relative: nil)
        return :confirm if current_lane_relative_path(workspace) && env_overlay_path_for?(relative, root_relative: current_lane_relative_path(workspace))
        return :deny if conversation_relative_path(workspace) && env_overlay_path_for?(relative, root_relative: conversation_relative_path(workspace))
        return :deny if lane_env_overlay_path?(relative)
        return :confirm if relative == "SOUL.md" || relative == "USER.md" || relative.start_with?("skills/")

        nil
      rescue ArgumentError
        nil
      end
      private_class_method :protected_path_rule

      def env_overlay_path_for?(relative_path, root_relative:)
        prefix = root_relative.to_s.presence
        return %w[.env .env.agent].include?(relative_path) if prefix.nil?

        [
          "#{prefix}/.env",
          "#{prefix}/.env.agent",
        ].include?(relative_path)
      end
      private_class_method :env_overlay_path_for?

      def lane_env_overlay_path?(relative_path)
        return false unless relative_path.include?("/.lanes/") || relative_path.start_with?(".lanes/")

        relative_path.end_with?("/.env", "/.env.agent")
      end
      private_class_method :lane_env_overlay_path?

      def current_lane_relative_path(workspace)
        relative_path_from_root(workspace[:lane_path], workspace.fetch(:root_path))
      end
      private_class_method :current_lane_relative_path

      def conversation_relative_path(workspace)
        relative_path_from_root(workspace[:conversation_path] || workspace[:cwd], workspace.fetch(:root_path))
      end
      private_class_method :conversation_relative_path

      def relative_path_from_root(path, root_path)
        return nil if path.nil?

        path.relative_path_from(root_path).to_s
      rescue ArgumentError
        nil
      end
      private_class_method :relative_path_from_root

      def ensure_within_root!(path, root_path)
        normalized = path.expand_path.to_s
        root = root_path.expand_path.to_s
        return if normalized == root || normalized.start_with?(root + File::SEPARATOR)

        raise SecurityError, "path escapes the workspace root"
      end
      private_class_method :ensure_within_root!
    end

    module_function

    def normalize_model_ref(model_ref:)
      ref = model_ref.to_s.strip
      provider_key, model_key = ref.split("/", 2).map(&:to_s)
      provider_key = provider_key.to_s.strip
      model_key = model_key.to_s.strip
      return ref if provider_key.empty? || model_key.empty?

      "#{provider_key}/#{model_key}"
    end

    def model_resolution_for(conversation:)
      catalog = Cybros::LLM::Catalog.effective
      agent_metadata = agent_metadata_for(conversation)
      agent = agent_for_manifest_defaults(conversation: conversation, agent_metadata: agent_metadata)
      preferred_models = preferred_models_for(agent_metadata: agent_metadata, agent: agent)
      model_ref =
        parse_explicit_model_ref(conversation&.metadata)&.join("/") ||
          default_model_ref_for(agent_metadata: agent_metadata, agent: agent, catalog: catalog)
      provider_key, model_key = validate_model_ref!(model_ref: model_ref).values_at(:provider_key, :model_key)
      model_spec = catalog.model(provider_key, model_key)

      {
        provider: nil,
        model: model_spec.fetch("api_model").to_s,
        preferred_models: preferred_models,
        matched_preference: preferred_models.any?,
        provider_name: catalog.provider(provider_key).fetch("display_name", nil).to_s.presence,
        provider_key: provider_key,
        model_key: model_key,
        model_ref: model_ref,
      }
    rescue AgentCore::ValidationError
      raise
    rescue StandardError
      requested_model_ref = conversation&.metadata&.dig("llm", "model_ref").to_s.strip
      if requested_model_ref.present?
        raise_model_not_found!(model_ref: requested_model_ref)
      end
      { provider: nil, model: nil, preferred_models: [], matched_preference: false, provider_name: nil }
    end

    def runtime_surface_resolution_for(conversation:, token_counter:)
      agent_metadata = agent_metadata_for(conversation)
      agent = agent_for_manifest_defaults(conversation: conversation, agent_metadata: agent_metadata)
      if agent.present?
        return build_runtime_surface_resolution(
          definition: { runtime_surface: agent.runtime_surface_config },
          token_counter: token_counter,
        )
      end

      profile_resolution = resolve_profile(agent_metadata_for(conversation))
      build_runtime_surface_resolution(
        definition: profile_resolution.fetch(:definition),
        token_counter: token_counter,
      )
    rescue StandardError
      build_runtime_surface_resolution(
        definition: {},
        token_counter: token_counter,
      )
    end

    def token_counter_for_model_ref(model_ref:)
      provider_key, model_key = validate_model_ref!(model_ref: model_ref).values_at(:provider_key, :model_key)
      model_spec = Cybros::LLM::Catalog.effective.model(provider_key, model_key)

      build_token_counter(model_spec: model_spec)
    end

    def validate_model_ref!(model_ref:)
      ref = normalize_model_ref(model_ref: model_ref)
      provider_key, model_key = ref.split("/", 2).map(&:to_s)
      provider_key = provider_key.to_s.strip
      model_key = model_key.to_s.strip

      if provider_key.empty? || model_key.empty?
        raise_model_not_found!(model_ref: ref, provider_key: provider_key, model_key: model_key)
      end

      catalog = Cybros::LLM::Catalog.effective

      provider_spec = catalog.provider(provider_key)
      enabled = provider_spec.fetch("enabled", true) != false
      AgentCore::ValidationError.raise!(
        "Selected provider is disabled",
        code: "cybros.llm.provider_disabled",
        details: { provider_key: provider_key },
      ) unless enabled

      environments = provider_spec.fetch("environments", nil)
      if environments.is_a?(Array) && !environments.include?(Rails.env.to_s)
        AgentCore::ValidationError.raise!(
          "Selected provider is not available in this environment",
          code: "cybros.llm.provider_unavailable_in_environment",
          details: { provider_key: provider_key, environment: Rails.env.to_s, allowed_environments: environments },
        )
      end

      models = provider_spec.fetch("models", {})
      model_spec = models.is_a?(Hash) ? models[model_key] : nil
      raise KeyError, "model missing" unless model_spec.is_a?(Hash)

      model_enabled = model_spec.fetch("enabled", true) != false
      AgentCore::ValidationError.raise!(
        "Selected model is disabled",
        code: "cybros.llm.model_disabled",
        details: { provider_key: provider_key, model_key: model_key },
      ) unless model_enabled

      ensure_credential_present!(provider_key: provider_key, provider_spec: provider_spec)

      { provider_key: provider_key, model_key: model_key }
    rescue KeyError
      raise_model_not_found!(model_ref: ref, provider_key: provider_key, model_key: model_key, catalog: catalog)
    end

    def default_model_ref_for(agent_metadata:, agent: nil, catalog: Cybros::LLM::Catalog.effective)
      site_default_model_ref = Account.instance.llm_default_model_ref.to_s.strip
      if site_default_model_ref.present?
        normalized_site_default = normalize_model_ref(model_ref: site_default_model_ref)
        if model_ref_in_catalog?(catalog: catalog, model_ref: normalized_site_default)
          validate_model_ref!(model_ref: normalized_site_default)
          return normalized_site_default
        end
      end

      normalized_catalog_default = normalize_model_ref(model_ref: catalog.default_model_ref)
      validate_model_ref!(model_ref: normalized_catalog_default)
      normalized_catalog_default
    end

    def usable_model_options(catalog: Cybros::LLM::Catalog.effective, env_name: Rails.env.to_s)
      raw_options =
        catalog.enabled_provider_keys_for_env(env_name).flat_map do |provider_key|
          provider_spec = catalog.provider(provider_key)
          next [] unless credential_present_for_provider?(provider_key: provider_key, provider_spec: provider_spec)

          models = provider_spec.fetch("models", {})
          next [] unless models.is_a?(Hash)

          models.map do |model_key, model_spec|
            next nil unless model_spec.is_a?(Hash)
            next nil if model_spec.fetch("enabled", true) == false

            {
              model_ref: "#{provider_key}/#{model_key}",
              model_display_name: model_spec.fetch("display_name").to_s,
              label: model_spec.fetch("display_name").to_s,
              provider_key: provider_key,
              provider_display_name: provider_spec.fetch("display_name").to_s,
              model_key: model_key.to_s,
              api_model: model_spec.fetch("api_model").to_s,
              supports_images: model_spec.dig("capabilities", "input", "image") == true,
            }
          end.compact
        end

      label_counts = raw_options.each_with_object(Hash.new(0)) { |option, counts| counts[option.fetch(:label)] += 1 }
      raw_options.map do |option|
        next option if label_counts.fetch(option.fetch(:label)) == 1

        option.merge(label: "#{option.fetch(:label)} (#{option.fetch(:provider_display_name)})")
      end
    end

    def model_ref_in_catalog?(catalog:, model_ref:)
      provider_key, model_key = normalize_model_ref(model_ref: model_ref).split("/", 2).map(&:to_s)
      return false if provider_key.blank? || model_key.blank?

      catalog.model(provider_key, model_key)
      true
    rescue KeyError
      false
    end
    private_class_method :model_ref_in_catalog?

    def raise_model_not_found!(model_ref:, provider_key: nil, model_key: nil, catalog: Cybros::LLM::Catalog.effective, details: {})
      ref = normalize_model_ref(model_ref: model_ref)
      resolved_provider_key, resolved_model_key = ref.split("/", 2).map(&:to_s)
      provider_key = provider_key.presence || resolved_provider_key
      model_key = model_key.presence || resolved_model_key

      suggestion = suggested_model_ref_for(provider_key: provider_key, model_key: model_key, catalog: catalog)
      message = +"Selected model is no longer available. Please reselect a model."
      if suggestion
        message << " If you meant api_model '#{suggestion.fetch(:api_model)}', use model_ref '#{suggestion.fetch(:model_ref)}'."
      end

      AgentCore::ValidationError.raise!(
        message,
        code: "cybros.llm.model_not_found",
        details: {
          provider_key: provider_key,
          model_key: model_key,
          model_ref: ref,
          suggested_model_ref: suggestion&.fetch(:model_ref, nil),
          suggested_api_model: suggestion&.fetch(:api_model, nil),
        }.merge(details),
      )
    end
    private_class_method :raise_model_not_found!

    def suggested_model_ref_for(provider_key:, model_key:, catalog:)
      return nil if provider_key.blank? || model_key.blank?

      provider_spec = catalog.provider(provider_key)
      return nil unless provider_spec.is_a?(Hash)

      models = provider_spec.fetch("models", {})
      return nil unless models.is_a?(Hash)

      canonical_model_key = model_key.tr("/", "-")
      canonical_model_spec = models[canonical_model_key]
      if canonical_model_spec.is_a?(Hash)
        canonical_api_model = canonical_model_spec.fetch("api_model", "").to_s
        if canonical_api_model == model_key
          return { model_ref: "#{provider_key}/#{canonical_model_key}", api_model: canonical_api_model }
        end
      end

      matches =
        models.filter_map do |candidate_model_key, model_spec|
          next unless model_spec.is_a?(Hash)

          api_model = model_spec.fetch("api_model", "").to_s
          next unless api_model == model_key

          { model_ref: "#{provider_key}/#{candidate_model_key}", api_model: api_model }
        end

      if matches.many?
        preferred = matches.reject { |match| match.fetch(:model_ref).include?("-live-acceptance") }
        matches = preferred if preferred.any?
      end

      return nil unless matches.one?

      matches.first
    rescue KeyError
      nil
    end
    private_class_method :suggested_model_ref_for

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

    def resolved_base_tool_policy(conversation_run:, base_tool_policy:, tools_registry:)
      return base_tool_policy if base_tool_policy.present?

      permission_mode = conversation_run&.effective_permission_mode.to_s.strip
      return AgentCore::Resources::Tools::Policy::ConfirmAll.new if permission_mode.blank?

      Cybros::Permissions::BundleCompiler.compile(
        permission_mode: permission_mode,
        tools_registry: tools_registry,
      ).fetch(:tool_policy)
    rescue AgentCore::ValidationError
      raise
    rescue StandardError
      AgentCore::Resources::Tools::Policy::ConfirmAll.new
    end
    private_class_method :resolved_base_tool_policy

    def channel_for(node:)
      from_node = routing_channel_from_metadata(node&.metadata)
      return from_node if from_node

      conversation = conversation_for(node)
      from_conversation = routing_channel_from_metadata(conversation&.metadata)
      return from_conversation if from_conversation

      nil
    end

    def runtime_for(node:, provider: nil, base_tool_policy: nil, tools_registry: nil, instrumenter: nil)
      conversation = conversation_for(node)
      conversation_run = latest_conversation_run_for(node)

      agent_metadata = agent_metadata_for(conversation)
      agent = agent_for_manifest_defaults(conversation: conversation, agent_metadata: agent_metadata)
      llm_selection =
        resolve_llm_selection(
          node: node,
          agent_metadata: agent_metadata,
          agent: agent,
          selected_model_ref_override: conversation_run&.selected_model_ref,
        )
      skills_store = build_skills_store(agent: agent)
      tools_registry ||= build_tools_registry(skills_store: skills_store)
      programmable_provider = programmable_provider_for(conversation_run, delegate: llm_selection.fetch(:provider, nil))
      ensure_programmable_runtime_available!(
        node: node,
        conversation: conversation,
        conversation_run: conversation_run,
        agent_metadata: agent_metadata,
        agent: agent,
        provider: provider,
        programmable_provider: programmable_provider,
        tools_registry: tools_registry,
      )
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

      base_tool_policy =
        resolved_base_tool_policy(
          conversation_run: conversation_run,
          base_tool_policy: base_tool_policy,
          tools_registry: tools_registry,
        )

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
        begin
          profiled_policy =
            AgentCore::Resources::Tools::Policy::Profiled.new(
              allowed: Array(definition.fetch(:tool_patterns)),
              delegate: delegate,
              tool_groups: nil,
            )

          if definition.fetch(:phase_0_auto_allow_memory_and_skills, true)
            phase_0_tool_policy(base_tool_policy: profiled_policy)
          else
            profiled_policy
          end
        end
      tool_policy = protected_agent_root_tool_policy(delegate: tool_policy)
      tool_policy = context_budget_tool_policy(delegate: tool_policy)

      provider ||= programmable_provider || llm_selection.fetch(:provider)
      instrumenter ||= build_instrumenter

      prompt_injection_sources =
        AgentCore::Resources::PromptInjections::Factory.build_sources(
          specs: definition.fetch(:prompt_injections, []),
          text_store: nil,
        )
      runtime_surface_resolution =
        if agent.present?
          build_runtime_surface_resolution(
            definition: { runtime_surface: agent.runtime_surface_config },
            token_counter: llm_selection.fetch(:token_counter, nil),
          )
        else
          build_runtime_surface_resolution(
            definition: definition,
            token_counter: llm_selection.fetch(:token_counter, nil),
          )
        end

      runtime_kwargs = {
        provider: provider,
        model: llm_selection.fetch(:api_model),
        tools_registry: tools_registry,
        tool_policy: tool_policy,
        instrumenter: instrumenter,
        prompt_mode: definition.fetch(:prompt_mode, :full),
        skills_store: skills_store,
        memory_search_limit: definition.fetch(:memory_search_limit) { Cybros::AgentProfiles::DEFAULT_MEMORY_SEARCH_LIMIT },
        prompt_injection_sources: prompt_injection_sources,
        include_skill_locations: definition.fetch(:include_skill_locations, false),
        directives_config: definition.fetch(:directives_config, nil),
        system_prompt_section_overrides: definition.fetch(:system_prompt_section_overrides, {}),
        runtime_surface: runtime_surface_resolution.fetch(:runtime_surface),
        runtime_surface_runner: runtime_surface_resolution.fetch(:runtime_surface_runner),
      }

      runtime_kwargs[:token_counter] = llm_selection.fetch(:token_counter, nil) if llm_selection.key?(:token_counter)
      runtime_kwargs[:context_window_tokens] = llm_selection.fetch(:context_window_tokens, nil) if llm_selection.key?(:context_window_tokens)
      runtime_kwargs[:model_context_window_tokens] = llm_selection.fetch(:model_context_window_tokens, nil) if llm_selection.key?(:model_context_window_tokens)
      runtime_kwargs[:provider_context_window_tokens] = llm_selection.fetch(:provider_context_window_tokens, nil) if llm_selection.key?(:provider_context_window_tokens)
      runtime_kwargs[:context_soft_limit_tokens] = llm_selection.fetch(:context_soft_limit_tokens, nil) if llm_selection.key?(:context_soft_limit_tokens)
      runtime_kwargs[:context_soft_limit_ratio] = llm_selection.fetch(:context_soft_limit_ratio, nil) if llm_selection.key?(:context_soft_limit_ratio)
      runtime_kwargs[:context_budget_policy] = llm_selection.fetch(:context_budget_policy, nil) if llm_selection.key?(:context_budget_policy)
      runtime_llm_options =
        runtime_llm_options_for(
          conversation: conversation,
          conversation_run: conversation_run,
          agent: agent,
          llm_selection: llm_selection,
        )
      runtime_kwargs[:llm_options] = runtime_llm_options if runtime_llm_options.any?

      runtime_kwargs[:context_turns] = context_turns if context_turns

      agent_key = agent_metadata&.fetch("key", nil).to_s.strip
      agent_key = "main" if agent_key.empty?

      agent_attrs = { key: agent_key, agent_profile: profile_name }
      agent_attrs[:id] = agent.id if agent.present?
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
      if (runtime_governance = llm_selection.fetch(:runtime_governance, nil)).is_a?(Hash) && runtime_governance.any?
        ctx_attrs[:runtime_governance] = runtime_governance
      end
      if conversation.present?
        cybros_attrs = {
          session_context: Cybros::ProgrammableAgent::SessionContext.from_conversation(conversation).to_h,
          execution_context: Cybros::ProgrammableAgent::ExecutionContext.from_conversation_node(
            conversation: conversation,
            node: node,
          ).to_h,
        }
        capability_snapshot = conversation_run&.snapshot&.dig("capability_snapshot")
        capability_snapshot = conversation_run&.recognized_deployment&.capability_snapshot unless capability_snapshot.is_a?(Hash)
        if capability_snapshot.is_a?(Hash) && capability_snapshot.any?
          cybros_attrs[:capability_snapshot] = AgentCore::Utils.deep_stringify_keys(capability_snapshot)
        end
        tool_surface = conversation_run&.snapshot&.dig("draft", "planning", "tool_surface")
        if tool_surface.is_a?(Hash) && tool_surface.any?
          cybros_attrs[:tool_surface] = AgentCore::Utils.deep_stringify_keys(tool_surface)
        end
        ctx_attrs[:cybros] = cybros_attrs
      end
      ctx_attrs[:runtime_surface] = runtime_surface_resolution.fetch(:execution_context_attributes)
      runtime_kwargs[:execution_context_attributes] = ctx_attrs

      AgentCore::DAG::Runtime.new(**runtime_kwargs)
    end

    def runtime_llm_options_for(conversation:, conversation_run:, agent:, llm_selection:)
      base_llm_options =
        if conversation_run&.effective_agent_config.is_a?(Hash)
          conversation_run.effective_agent_config["llm_options"]
        elsif conversation.present? && agent.present?
          conversation.selected_agent_config_for(agent)["llm_options"]
        end

      options = base_llm_options.is_a?(Hash) ? AgentCore::Utils.deep_symbolize_keys(base_llm_options) : {}

      runtime_governance = llm_selection.fetch(:runtime_governance, nil)
      if runtime_governance.is_a?(Hash) && runtime_governance.any?
        options[:runtime_governance] = runtime_governance
      end

      options
    end
    private_class_method :runtime_llm_options_for

    def resolve_llm_selection(node:, agent_metadata:, agent:, selected_model_ref_override: nil)
      catalog = Cybros::LLM::Catalog.effective

      conversation = conversation_for(node)
      explicit_model_ref =
        normalize_model_ref(model_ref: selected_model_ref_override) if selected_model_ref_override.present?
      explicit_model_ref ||=
        parse_explicit_model_ref(node&.metadata)&.join("/") ||
          parse_explicit_model_ref(conversation&.metadata)&.join("/")
      selected_model_ref =
        if explicit_model_ref.present?
          validate_model_ref!(model_ref: explicit_model_ref)
          normalize_model_ref(model_ref: explicit_model_ref)
        else
          default_model_ref_for(agent_metadata: agent_metadata, agent: agent, catalog: catalog)
        end

      provider_key, model_key = selected_model_ref.split("/", 2).map(&:to_s)

      provider_spec = catalog.provider(provider_key)
      model_spec = catalog.model(provider_key, model_key)

      built =
        build_llm_selection(
          provider_key: provider_key,
          model_key: model_key,
          provider_spec: provider_spec,
          model_spec: model_spec,
        )

      built
    end
    private_class_method :resolve_llm_selection

    def programmable_provider_for(conversation_run, delegate:)
      return nil unless conversation_run&.programmable?
      return nil if delegate.nil?

      Cybros::ProgrammableAgentProvider.new(conversation_run: conversation_run, delegate: delegate)
    end
    private_class_method :programmable_provider_for

    def ensure_programmable_runtime_available!(node:, conversation:, conversation_run:, agent_metadata:, agent:, provider:, programmable_provider:, tools_registry:)
      return if provider.present?
      return if explicit_agent_profile_metadata?(agent_metadata)
      return unless agent.present?
      return if programmable_provider.present?
      return if kernel_task_executable_without_materialized_run?(node: node, tools_registry: tools_registry)

      AgentCore::ValidationError.raise!(
        "Interactive programmable runtime requires a materialized ConversationRun.",
        code: "cybros.agent_runtime_resolver.programmable_run_required",
        details: {
          conversation_id: conversation&.id,
          conversation_run_id: conversation_run&.id,
          dag_node_id: node&.id,
          agent_id: agent&.id,
        }.compact,
      )
    end
    private_class_method :ensure_programmable_runtime_available!

    def kernel_task_executable_without_materialized_run?(node:, tools_registry:)
      return false unless node&.node_type.to_s == Messages::Task.node_type_key

      input = node.body_input.is_a?(Hash) ? node.body_input : {}
      return false if input["implementation_source"].to_s == "agent"

      tool_name =
        input["logical_tool_name"].to_s.presence ||
          input["name"].to_s.presence ||
          input["requested_name"].to_s.presence
      return false if tool_name.blank?
      return false unless tools_registry.respond_to?(:include?)

      tools_registry.include?(tool_name)
    end
    private_class_method :kernel_task_executable_without_materialized_run?

    def latest_conversation_run_for(node)
      ConversationRun.latest_for_node(node)
    end
    private_class_method :latest_conversation_run_for

    def parse_explicit_model_ref(metadata)
      return nil unless metadata.is_a?(Hash)

      llm = metadata["llm"]
      llm = {} unless llm.is_a?(Hash)

      model_ref = llm["model_ref"].to_s.strip
      provider_key = llm["provider_key"].to_s.strip
      model_key = llm["model_key"].to_s.strip

      if model_ref.present?
        pk, mk = normalize_model_ref(model_ref: model_ref).split("/", 2).map(&:to_s)
        provider_key = pk.to_s.strip
        model_key = mk.to_s.strip
      end

      return nil if provider_key.empty? || model_key.empty?

      [provider_key, model_key]
    end
    private_class_method :parse_explicit_model_ref

    def ensure_credential_present!(provider_key:, provider_spec:)
      return if credential_present_for_provider?(provider_key: provider_key, provider_spec: provider_spec)

      AgentCore::ValidationError.raise!(
        "Provider credential missing. Please configure credentials and try again.",
        code: "cybros.llm.credential_missing",
        details: { provider_key: provider_key, credential_type: provider_spec.fetch("credential_type", "api_key").to_s },
      )
    end
    private_class_method :ensure_credential_present!

    def credential_present_for_provider?(provider_key:, provider_spec:)
      requires = provider_spec.fetch("requires_credential") == true
      return true unless requires

      credential_type = provider_spec.fetch("credential_type", "api_key").to_s
      credential = active_provider_credential_for(provider_key: provider_key)

      if credential_type == "oauth_codex"
        refresh_token = credential&.refresh_token.to_s
        access_token = credential&.access_token.to_s
        expires_at = credential&.expires_at
        refresh_token.present? || (access_token.present? && expires_at.is_a?(Time) && expires_at > (Time.current + 60))
      else
        credential&.api_key.to_s.present?
      end
    rescue StandardError
      false
    end
    private_class_method :credential_present_for_provider?

    def build_llm_selection(provider_key:, model_key:, provider_spec:, model_spec:)
      enabled = provider_spec.fetch("enabled", true) != false
      AgentCore::ValidationError.raise!(
        "Selected provider is disabled",
        code: "cybros.llm.provider_disabled",
        details: { provider_key: provider_key },
      ) unless enabled

      model_enabled = model_spec.fetch("enabled", true) != false
      AgentCore::ValidationError.raise!(
        "Selected model is disabled",
        code: "cybros.llm.model_disabled",
        details: { provider_key: provider_key, model_key: model_key },
      ) unless model_enabled

      model_protocol = model_spec.dig("capabilities", "protocol").to_s
      provider_protocol = provider_spec.fetch("wire_api").to_s
      if model_protocol.present? && model_protocol != provider_protocol
        AgentCore::ValidationError.raise!(
          "Selected model protocol does not match provider protocol",
          code: "cybros.llm.protocol_mismatch",
          details: {
            provider_key: provider_key,
            model_key: model_key,
            model_protocol: model_protocol,
            provider_protocol: provider_protocol,
          },
        )
      end

      transport = provider_spec.fetch("transport").to_s
      if provider_protocol == "responses" && transport == "websocket"
        AgentCore::ValidationError.raise!(
          "Responses websocket transport is not supported yet",
          code: "cybros.llm.transport.websocket_not_supported_yet",
          details: { provider_key: provider_key },
        )
      end

      api_model = model_spec.fetch("api_model").to_s
      tokenizer_hint = model_spec.fetch("tokenizer_hint", nil).to_s.strip
      tokenizer_hint = Cybros::TokenEstimation.canonical_model_hint(api_model) if tokenizer_hint.empty?

      token_counter = build_token_counter(model_spec: model_spec, api_model: api_model, tokenizer_hint: tokenizer_hint)

      base_url = provider_spec.fetch("base_url").to_s
      headers = provider_spec.fetch("headers", {})
      headers = {} unless headers.is_a?(Hash)
      responses_path = provider_spec.fetch("responses_path", nil).to_s
      responses_path = nil if responses_path.strip.empty?

      provider_defaults = provider_spec.fetch("request_defaults", {})
      provider_defaults = {} unless provider_defaults.is_a?(Hash)
      model_defaults = model_spec.fetch("request_defaults", {})
      model_defaults = {} unless model_defaults.is_a?(Hash)
      request_defaults = provider_defaults.deep_merge(model_defaults)

      requires_credential = provider_spec.fetch("requires_credential") == true
      credential_type = provider_spec.fetch("credential_type", "api_key").to_s
      credential = active_provider_credential_for(provider_key: provider_key)
      transport = provider_spec.fetch("transport", nil).to_s.strip

      if requires_credential && credential_type == "oauth_codex" && credential
        begin
          Cybros::LLM::CodexOAuth.refresh_if_needed!(credential)
          credential.reload
        rescue Cybros::LLM::CodexOAuthError => e
          AgentCore::ValidationError.raise!(
            "OAuth refresh failed. Please re-authenticate.",
            code: "cybros.llm.oauth_refresh_failed",
            details: { provider_key: provider_key, error_code: e.error_code, message: e.message },
          )
        end
      end

      api_key =
        if requires_credential && credential_type == "api_key"
          credential&.api_key.to_s.presence
        else
          credential&.api_key.to_s.presence
        end

      oauth_present =
        if requires_credential && credential_type == "oauth_codex"
          credential&.refresh_token.to_s.present? || credential&.access_token.to_s.present?
        else
          true
        end

      built_provider =
        if requires_credential && credential_type == "api_key" && api_key.blank?
          nil
        elsif requires_credential && credential_type == "oauth_codex" && oauth_present == false
          nil
        else
          effective_headers = headers.dup
          if credential_type == "oauth_codex"
            at = credential&.access_token.to_s
            if at.present?
              ensure_safe_header_value!(at, header: "Authorization")
              effective_headers["Authorization"] = "Bearer #{at}"
            end
            account_id = credential&.account_id.to_s
            if account_id.present?
              ensure_safe_header_value!(account_id, header: "ChatGPT-Account-Id")
              effective_headers["ChatGPT-Account-Id"] = account_id
            end
          end

          AgentCore::Resources::Provider::SimpleInferenceProvider.new(
            base_url: base_url,
            api_key: (credential_type == "oauth_codex" ? nil : api_key),
            headers: effective_headers,
            wire_api: provider_protocol.to_sym,
            responses_path: responses_path,
            transport: transport,
            request_defaults: request_defaults,
          )
        end

      supports_tools = model_spec.dig("capabilities", "tools", "tool_calling") == true
      supports_images = model_spec.dig("capabilities", "input", "image") == true
      model_ref = "#{provider_key}/#{model_key}"
      model_context_window_tokens = model_spec.fetch("context_window_tokens")
      provider_context_window_tokens = provider_spec.fetch("context_window_tokens", nil)
      effective_context_window_tokens =
        if provider_context_window_tokens.nil? || provider_context_window_tokens == 0
          model_context_window_tokens
        else
          [model_context_window_tokens, provider_context_window_tokens].min
        end

      gated_provider =
        if built_provider
          Cybros::LLM::CapabilityGatedProvider.new(
            delegate: built_provider,
            provider_key: provider_key,
            model_ref: model_ref,
            api_model: api_model,
            supports_tools: supports_tools,
            supports_images: supports_images,
          )
        end

      {
        provider: gated_provider,
        api_model: api_model,
        provider_key: provider_key,
        provider_credential_id: credential&.id,
        model_key: model_key,
        model_ref: model_ref,
        runtime_governance: {
          provider_credential_id: credential&.id,
          provider_key: provider_key,
        }.compact,
        token_counter: token_counter,
        context_window_tokens: effective_context_window_tokens,
        model_context_window_tokens: model_context_window_tokens,
        provider_context_window_tokens: provider_context_window_tokens,
        context_soft_limit_tokens: model_spec.fetch("context_soft_limit_tokens", nil),
        context_soft_limit_ratio: model_spec.fetch("context_soft_limit_ratio", nil),
        context_budget_policy: Cybros::ContextBudget::DefaultPolicy,
      }
    rescue KeyError => e
      raise_model_not_found!(
        model_ref: model_ref,
        provider_key: provider_key,
        model_key: model_key,
        details: { error: e.message },
      )
    end
    private_class_method :build_llm_selection

    def ensure_safe_header_value!(value, header:)
      s = value.to_s
      return if s.exclude?("\r") && s.exclude?("\n")

      AgentCore::ValidationError.raise!(
        "Invalid credential value for request header",
        code: "cybros.llm.invalid_credential_value",
        details: { header: header },
      )
    end
    private_class_method :ensure_safe_header_value!

    def active_provider_credential_for(provider_key:)
      LLMProviderCredential.find_by(provider_key: provider_key, status: "active")
    end
    private_class_method :active_provider_credential_for

    def build_skills_store(agent:)
      ::Agents::SkillsStoreBuilder.build(agent: agent)
    end
    private_class_method :build_skills_store

    def build_tools_registry(skills_store: nil)
      registry = AgentCore::Resources::Tools::Registry.new
      registry.register_many(Cybros::Bootstrap::Tools.build)
      registry.register_many(Cybros::Attachments::Tools.build)
      registry.register_many(Cybros::AgentOwnedTools.build)
      registry.register_many(Cybros::ContextBudget::Tools.build)
      registry.register_many(Cybros::LaneProcesses::Tools.build)
      registry.register_many(Cybros::LaneState::Tools.build)
      registry.register_many(Cybros::Subagent::Tools.build)

      registry.register_skills_store(skills_store) if skills_store.present?

      registry
    end

    def context_budget_tool_policy(delegate:)
      AgentCore::Resources::Tools::Policy::Profiled.new(
        allowed: ["*"],
        hidden: ["compact_context", "merge_lane_state"],
        context_allowed: ->(context) { context_budget_action(context) == "advise_compact" ? ["compact_context"] : [] },
        delegate: delegate,
        tool_groups: nil,
      )
    end
    private_class_method :context_budget_tool_policy

    def protected_agent_root_tool_policy(delegate:)
      ProtectedAgentPathPolicy.new(delegate: delegate)
    end
    private_class_method :protected_agent_root_tool_policy

    def context_budget_action(context)
      attributes = context.attributes if context.respond_to?(:attributes)
      return nil unless attributes.is_a?(Hash)

      budget = attributes[:context_budget]
      return nil unless budget.is_a?(Hash)

      budget.fetch(:budget_action, nil).to_s.presence
    end
    private_class_method :context_budget_action

    def model_prefer_from_agent_metadata(agent_metadata)
      return [] unless agent_metadata.is_a?(Hash)

      prefer = agent_metadata.fetch("model_prefer", nil) || agent_metadata.fetch("model", nil)
      prefer = prefer.fetch("prefer", nil) if prefer.is_a?(Hash)

      Array(prefer).map { |v| v.to_s.strip }.reject(&:empty?).uniq
    end
    private_class_method :model_prefer_from_agent_metadata

    def model_prefer_from_agent(agent)
      return [] unless agent.respond_to?(:preferred_model_refs)

      Array(agent.preferred_model_refs).map { |value| value.to_s.strip }.reject(&:empty?).uniq
    end
    private_class_method :model_prefer_from_agent

    def preferred_models_for(agent_metadata:, agent:)
      if explicit_agent_profile_metadata?(agent_metadata)
        model_prefer_from_agent_metadata(agent_metadata)
      elsif agent.present?
        model_prefer_from_agent(agent)
      else
        model_prefer_from_agent_metadata(agent_metadata)
      end
    end
    private_class_method :preferred_models_for

    def build_instrumenter
      AgentCore::Observability::Adapters::ActiveSupportNotificationsInstrumenter.new
    end
    private_class_method :build_instrumenter

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
      graph = node.graph if node.respond_to?(:graph)
      attachable = graph&.attachable if graph.respond_to?(:attachable)
      attachable.is_a?(Conversation) ? attachable : nil
    end
    private_class_method :conversation_for

    def agent_metadata_for(conversation)
      meta = conversation&.metadata
      return nil unless meta.is_a?(Hash)

      agent = meta["agent"]
      agent.is_a?(Hash) ? agent.transform_keys(&:to_s) : nil
    end
    private_class_method :agent_metadata_for

    def agent_for_manifest_defaults(conversation:, agent_metadata:)
      return nil if explicit_agent_profile_metadata?(agent_metadata)

      conversation&.agent
    end
    private_class_method :agent_for_manifest_defaults

    def explicit_agent_profile_metadata?(agent_metadata)
      return false unless agent_metadata.is_a?(Hash) && agent_metadata.key?("agent_profile")

      raw = agent_metadata.fetch("agent_profile", nil)
      raw.is_a?(Hash) || raw.to_s.strip.present?
    end
    private_class_method :explicit_agent_profile_metadata?


    def routing_channel_from_metadata(metadata)
      return nil unless metadata.is_a?(Hash)

      routing = metadata["routing"]
      return nil unless routing.is_a?(Hash)

      channel = routing["channel"]
      channel = channel.to_s.lines.first.to_s.strip
      return nil if channel.empty?

      channel
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

    def build_runtime_surface_resolution(definition:, token_counter:)
      config = normalize_runtime_surface_config(definition.fetch(:runtime_surface, nil))

      helpers = {}
      if config.dig(:helpers, :estimate_tokens) == true
        helpers[:estimate_tokens] =
          lambda do |text, **|
            if token_counter.respond_to?(:count_text)
              token_counter.count_text(text.to_s)
            else
              text.to_s.bytesize
            end
          end
      end
      if config.dig(:helpers, :estimate_messages) == true
        helpers[:estimate_messages] =
          lambda do |messages, **|
            if token_counter.respond_to?(:count_messages)
              token_counter.count_messages(Array(messages))
            else
              Array(messages).sum do |message|
                message.respond_to?(:content) ? message.content.to_s.bytesize : message.to_s.bytesize
              end
            end
          end
      end

      {
        runtime_surface: build_runtime_surface(config),
        runtime_surface_runner: AgentCore::RuntimeSurface::Runner.new(
          helpers: helpers,
          stage_limits: config.fetch(:stage_limits),
        ),
        execution_context_attributes: {
          type: config.fetch(:type),
          helpers: helpers.keys.sort,
          stage_limits: config.fetch(:stage_limits),
        }.freeze,
      }
    end
    private_class_method :build_runtime_surface_resolution

    def normalize_runtime_surface_config(value)
      raw = value.is_a?(Hash) ? AgentCore::Utils.deep_symbolize_keys(value) : {}

      type = raw.fetch(:type, :noop).to_s.strip.downcase.tr("-", "_").to_sym
      return noop_runtime_surface_config unless type == :noop

      helpers = raw.fetch(:helpers, {})
      helpers = {} unless helpers.is_a?(Hash)
      normalized_helpers =
        helpers.each_with_object({}) do |(helper_name, enabled), out|
          key = helper_name.to_s.strip.downcase.tr("-", "_").to_sym
          next unless %i[estimate_tokens estimate_messages].include?(key)
          next unless enabled == true

          out[key] = true
        end.freeze

      stage_limits = raw.fetch(:stage_limits, {})
      stage_limits = {} unless stage_limits.is_a?(Hash)
      normalized_stage_limits =
        stage_limits.each_with_object({}) do |(stage_name, stage_cfg), out|
          key = stage_name.to_s.strip.downcase.tr("-", "_").to_sym
          next unless AgentCore::RuntimeSurface::LIFECYCLE_METHODS.include?(key)
          next unless stage_cfg.is_a?(Hash)

          cfg = AgentCore::Utils.deep_symbolize_keys(stage_cfg)
          entry = {}

          timeout_s = Float(cfg.fetch(:timeout_s, nil), exception: false)
          entry[:timeout_s] = timeout_s if timeout_s && timeout_s.positive? && timeout_s.finite?

          max_output_bytes = Integer(cfg.fetch(:max_output_bytes, nil), exception: false)
          entry[:max_output_bytes] = max_output_bytes if max_output_bytes && max_output_bytes.positive?

          out[key] = entry.freeze if entry.any?
        end.freeze

      {
        type: :noop,
        helpers: normalized_helpers,
        stage_limits: normalized_stage_limits,
      }.freeze
    end
    private_class_method :normalize_runtime_surface_config

    def noop_runtime_surface_config
      {
        type: :noop,
        helpers: {}.freeze,
        stage_limits: {}.freeze,
      }.freeze
    end
    private_class_method :noop_runtime_surface_config

    def build_token_counter(model_spec:, api_model: nil, tokenizer_hint: nil)
      resolved_api_model = api_model.presence || model_spec.fetch("api_model").to_s
      resolved_hint = tokenizer_hint.to_s.strip
      resolved_hint = model_spec.fetch("tokenizer_hint", nil).to_s.strip if resolved_hint.empty?
      resolved_hint = Cybros::TokenEstimation.canonical_model_hint(resolved_api_model) if resolved_hint.empty?

      token_estimator =
        Cybros::TokenEstimation.estimator(
          tokenizer_root_path: Cybros::TokenEstimation.tokenizer_root,
          strict: false,
        )

      AgentCore::Resources::TokenCounter::Estimator.new(
        token_estimator: token_estimator,
        model_hint: resolved_hint,
      )
    end
    private_class_method :build_token_counter

    def build_runtime_surface(config)
      case config.fetch(:type)
      when :noop
        AgentCore::RuntimeSurface.default
      else
        AgentCore::RuntimeSurface.default
      end
    end
    private_class_method :build_runtime_surface

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
