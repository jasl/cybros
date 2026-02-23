# frozen_string_literal: true

require "json"

module Cybros
  # User-provided agent profile configuration (safe, data-only).
  #
  # This is intended to be deserialized from untrusted input (API params / JSON)
  # and applied on top of a built-in Cybros::AgentProfiles profile.
  AgentProfileConfig =
    Data.define(
      :base_profile,
      :context_turns,
      :prompt_mode,
      :memory_search_limit,
      :tools_allowed,
      :repo_docs_enabled,
      :repo_docs_max_total_bytes,
      :system_prompt_sections,
    ) do
      MAX_CONTEXT_TURNS = 1000
      MAX_MEMORY_SEARCH_LIMIT = 20
      MAX_REPO_DOCS_TOTAL_BYTES = 200_000
      MAX_TOOL_PATTERNS = 200
      MAX_TOOL_PATTERN_BYTES = 128
      MAX_SYSTEM_PROMPT_SECTIONS = 50
      SYSTEM_PROMPT_SECTION_IDS = %w[
        safety
        tooling
        workspace
        available_skills
        channel
        time
        memory_relevant_context
      ].freeze

      def self.from_value(value)
        case value
        when nil
          nil
        when self
          value
        when Hash
          from_hash(value)
        when String
          from_json(value)
        else
          AgentCore::ValidationError.raise!(
            "agent_profile must be a Hash or JSON string",
            code: "cybros.agent_profile_config.agent_profile_must_be_a_hash_or_json_string",
            details: { value_class: value.class.name },
          )
        end
      end

      def self.from_json(value)
        parsed = JSON.parse(value.to_s)
        unless parsed.is_a?(Hash)
          AgentCore::ValidationError.raise!(
            "agent_profile JSON must decode to an object",
            code: "cybros.agent_profile_config.agent_profile_json_must_decode_to_an_object",
          )
        end

        from_hash(parsed)
      rescue JSON::ParserError
        AgentCore::ValidationError.raise!(
          "agent_profile JSON is invalid",
          code: "cybros.agent_profile_config.agent_profile_json_is_invalid",
        )
      end

      def self.from_hash(value)
        unless value.is_a?(Hash)
          AgentCore::ValidationError.raise!(
            "agent_profile must be an object",
            code: "cybros.agent_profile_config.agent_profile_must_be_an_object",
            details: { value_class: value.class.name },
          )
        end

        h = AgentCore::Utils.deep_stringify_keys(value)
        unknown = h.keys - allowed_keys
        if unknown.any?
          AgentCore::ValidationError.raise!(
            "agent_profile contains unknown keys: #{unknown.sort.join(", ")}",
            code: "cybros.agent_profile_config.agent_profile_contains_unknown_keys",
            details: { unknown_keys: unknown.sort },
          )
        end

        base_profile = normalize_base_profile(h)
        context_turns = parse_context_turns(h)
        prompt_mode = parse_prompt_mode(h)
        memory_search_limit = parse_memory_search_limit(h)
        tools_allowed = parse_tools_allowed(h)
        repo_docs_enabled = parse_repo_docs_enabled(h)
        repo_docs_max_total_bytes = parse_repo_docs_max_total_bytes(h)
        system_prompt_sections = parse_system_prompt_sections(h)

        new(
          base_profile: base_profile,
          context_turns: context_turns,
          prompt_mode: prompt_mode,
          memory_search_limit: memory_search_limit,
          tools_allowed: tools_allowed,
          repo_docs_enabled: repo_docs_enabled,
          repo_docs_max_total_bytes: repo_docs_max_total_bytes,
          system_prompt_sections: system_prompt_sections,
        )
      end

      def to_metadata
        out = { "base" => base_profile }
        out["context_turns"] = context_turns if context_turns
        out["prompt_mode"] = prompt_mode.to_s if prompt_mode
        out["memory_search_limit"] = memory_search_limit if memory_search_limit
        out["tools_allowed"] = tools_allowed if tools_allowed
        out["repo_docs_enabled"] = repo_docs_enabled unless repo_docs_enabled.nil?
        out["repo_docs_max_total_bytes"] = repo_docs_max_total_bytes if repo_docs_max_total_bytes
        out["system_prompt_sections"] = self.class.send(:system_prompt_sections_to_metadata, system_prompt_sections) if system_prompt_sections
        out
      end

      def apply_overrides(definition)
        return definition unless definition.is_a?(Hash)

        out = definition.dup

        if prompt_mode
          out[:prompt_mode] = prompt_mode
        end

        if memory_search_limit
          out[:memory_search_limit] = memory_search_limit
        end

        injections = Array(out[:prompt_injections])

        if repo_docs_enabled == false
          injections = injections.reject { |spec| spec.is_a?(Hash) && spec.fetch(:type, nil).to_s == "repo_docs" }
        end

        if repo_docs_max_total_bytes
          injections =
            injections.map do |spec|
              next spec unless spec.is_a?(Hash) && spec.fetch(:type, nil).to_s == "repo_docs"
              spec.merge(max_total_bytes: repo_docs_max_total_bytes)
            end
        end

        out[:prompt_injections] = injections

        if system_prompt_sections
          base = out.fetch(:system_prompt_section_overrides, {})
          base = base.is_a?(Hash) ? AgentCore::Utils.deep_symbolize_keys(base) : {}
          extra = AgentCore::Utils.deep_symbolize_keys(system_prompt_sections)

          merged = base.dup
          extra.each do |section_id, cfg|
            existing = merged[section_id]
            merged[section_id] =
              if existing.is_a?(Hash) && cfg.is_a?(Hash)
                existing.merge(cfg)
              else
                cfg
              end
          end

          out[:system_prompt_section_overrides] = merged
        end

        out
      end

      private_class_method def self.allowed_keys
        %w[
          base
          context_turns
          prompt_mode
          memory_search_limit
          tools_allowed
          repo_docs_enabled
          repo_docs_max_total_bytes
          system_prompt_sections
        ]
      end

      private_class_method def self.normalize_base_profile(h)
        raw = h.fetch("base", nil)

        base = raw.to_s.strip.downcase
        if base.empty?
          AgentCore::ValidationError.raise!(
            "agent_profile.base is required",
            code: "cybros.agent_profile_config.base_is_required",
          )
        end

        unless Cybros::AgentProfiles.valid?(base)
          AgentCore::ValidationError.raise!(
            "agent_profile.base must be one of: #{Cybros::AgentProfiles::PROFILES.keys.sort.join(", ")}",
            code: "cybros.agent_profile_config.base_must_be_one_of",
            details: { base: base },
          )
        end

        base
      end

      private_class_method def self.parse_context_turns(h)
        return nil unless h.key?("context_turns")

        value = Integer(h.fetch("context_turns", nil), exception: false)
        unless value
          AgentCore::ValidationError.raise!(
            "context_turns must be an Integer",
            code: "cybros.agent_profile_config.context_turns_must_be_an_integer",
            details: { value_class: h.fetch("context_turns", nil).class.name },
          )
        end

        if value < 1 || value > MAX_CONTEXT_TURNS
          AgentCore::ValidationError.raise!(
            "context_turns must be between 1 and #{MAX_CONTEXT_TURNS}",
            code: "cybros.agent_profile_config.context_turns_out_of_range",
            details: { context_turns: value },
          )
        end

        value
      end

      private_class_method def self.parse_prompt_mode(h)
        return nil unless h.key?("prompt_mode")

        mode = h.fetch("prompt_mode", nil).to_s.strip.downcase.tr("-", "_").to_sym
        allowed = AgentCore::Resources::PromptInjections::PROMPT_MODES
        unless allowed.include?(mode)
          AgentCore::ValidationError.raise!(
            "prompt_mode must be one of: #{allowed.map(&:to_s).sort.join(", ")}",
            code: "cybros.agent_profile_config.prompt_mode_must_be_one_of",
            details: { prompt_mode: mode.to_s },
          )
        end

        mode
      end

      private_class_method def self.parse_memory_search_limit(h)
        return nil unless h.key?("memory_search_limit")

        value = Integer(h.fetch("memory_search_limit", nil), exception: false)
        unless value
          AgentCore::ValidationError.raise!(
            "memory_search_limit must be an Integer",
            code: "cybros.agent_profile_config.memory_search_limit_must_be_an_integer",
            details: { value_class: h.fetch("memory_search_limit", nil).class.name },
          )
        end

        if value < 0 || value > MAX_MEMORY_SEARCH_LIMIT
          AgentCore::ValidationError.raise!(
            "memory_search_limit must be between 0 and #{MAX_MEMORY_SEARCH_LIMIT}",
            code: "cybros.agent_profile_config.memory_search_limit_out_of_range",
            details: { memory_search_limit: value },
          )
        end

        value
      end

      private_class_method def self.parse_tools_allowed(h)
        return nil unless h.key?("tools_allowed")

        value = h.fetch("tools_allowed", nil)
        unless value.is_a?(Array)
          AgentCore::ValidationError.raise!(
            "tools_allowed must be an Array of Strings",
            code: "cybros.agent_profile_config.tools_allowed_must_be_an_array_of_strings",
            details: { value_class: value.class.name },
          )
        end

        patterns =
          Array(value).map do |entry|
            entry.to_s.strip
          end.reject(&:empty?)

        if patterns.length > MAX_TOOL_PATTERNS
          AgentCore::ValidationError.raise!(
            "tools_allowed is too large (max #{MAX_TOOL_PATTERNS})",
            code: "cybros.agent_profile_config.tools_allowed_too_large",
            details: { tools_allowed_count: patterns.length },
          )
        end

        too_long = patterns.find { |p| p.bytesize > MAX_TOOL_PATTERN_BYTES }
        if too_long
          AgentCore::ValidationError.raise!(
            "tools_allowed pattern is too long (max #{MAX_TOOL_PATTERN_BYTES} bytes)",
            code: "cybros.agent_profile_config.tools_allowed_pattern_too_long",
            details: { pattern_bytes: too_long.bytesize },
          )
        end

        patterns.freeze
      end

      private_class_method def self.parse_repo_docs_enabled(h)
        return nil unless h.key?("repo_docs_enabled")

        value = h.fetch("repo_docs_enabled", nil)
        if value == true || value == false
          value
        else
          AgentCore::ValidationError.raise!(
            "repo_docs_enabled must be a boolean",
            code: "cybros.agent_profile_config.repo_docs_enabled_must_be_a_boolean",
            details: { value_class: value.class.name },
          )
        end
      end

      private_class_method def self.parse_repo_docs_max_total_bytes(h)
        return nil unless h.key?("repo_docs_max_total_bytes")

        value = Integer(h.fetch("repo_docs_max_total_bytes", nil), exception: false)
        unless value
          AgentCore::ValidationError.raise!(
            "repo_docs_max_total_bytes must be an Integer",
            code: "cybros.agent_profile_config.repo_docs_max_total_bytes_must_be_an_integer",
            details: { value_class: h.fetch("repo_docs_max_total_bytes", nil).class.name },
          )
        end

        if value < 0 || value > MAX_REPO_DOCS_TOTAL_BYTES
          AgentCore::ValidationError.raise!(
            "repo_docs_max_total_bytes must be between 0 and #{MAX_REPO_DOCS_TOTAL_BYTES}",
            code: "cybros.agent_profile_config.repo_docs_max_total_bytes_out_of_range",
            details: { repo_docs_max_total_bytes: value },
          )
        end

        value
      end

      private_class_method def self.parse_system_prompt_sections(h)
        return nil unless h.key?("system_prompt_sections")

        raw = h.fetch("system_prompt_sections", nil)
        unless raw.is_a?(Hash)
          AgentCore::ValidationError.raise!(
            "system_prompt_sections must be an object",
            code: "cybros.agent_profile_config.system_prompt_sections_must_be_an_object",
            details: { value_class: raw.class.name },
          )
        end

        if raw.length > MAX_SYSTEM_PROMPT_SECTIONS
          AgentCore::ValidationError.raise!(
            "system_prompt_sections is too large (max #{MAX_SYSTEM_PROMPT_SECTIONS})",
            code: "cybros.agent_profile_config.system_prompt_sections_too_large",
            details: { system_prompt_sections_count: raw.length },
          )
        end

        out = {}

        raw.each do |raw_id, raw_cfg|
          section_id = raw_id.to_s.strip.downcase.tr("-", "_")
          unless SYSTEM_PROMPT_SECTION_IDS.include?(section_id)
            AgentCore::ValidationError.raise!(
              "system_prompt_sections contains unknown section id: #{section_id}",
              code: "cybros.agent_profile_config.system_prompt_sections_unknown_section_id",
              details: { section_id: section_id },
            )
          end

          unless raw_cfg.is_a?(Hash)
            AgentCore::ValidationError.raise!(
              "system_prompt_sections.#{section_id} must be an object",
              code: "cybros.agent_profile_config.system_prompt_sections_entry_must_be_an_object",
              details: { section_id: section_id, value_class: raw_cfg.class.name },
            )
          end

          cfg = AgentCore::Utils.deep_stringify_keys(raw_cfg)
          unknown_keys = cfg.keys - %w[enabled order prompt_modes stability]
          if unknown_keys.any?
            AgentCore::ValidationError.raise!(
              "system_prompt_sections.#{section_id} contains unknown keys: #{unknown_keys.sort.join(", ")}",
              code: "cybros.agent_profile_config.system_prompt_sections_entry_contains_unknown_keys",
              details: { section_id: section_id, unknown_keys: unknown_keys.sort },
            )
          end

          parsed = {}

          if cfg.key?("enabled")
            value = cfg.fetch("enabled", nil)
            if value == true || value == false
              parsed[:enabled] = value
            else
              AgentCore::ValidationError.raise!(
                "system_prompt_sections.#{section_id}.enabled must be a boolean",
                code: "cybros.agent_profile_config.system_prompt_sections_enabled_must_be_a_boolean",
                details: { section_id: section_id, value_class: value.class.name },
              )
            end
          end

          if cfg.key?("order")
            value = Integer(cfg.fetch("order", nil), exception: false)
            unless value
              AgentCore::ValidationError.raise!(
                "system_prompt_sections.#{section_id}.order must be an Integer",
                code: "cybros.agent_profile_config.system_prompt_sections_order_must_be_an_integer",
                details: { section_id: section_id, value_class: cfg.fetch("order", nil).class.name },
              )
            end

            if value < -10_000 || value > 10_000
              AgentCore::ValidationError.raise!(
                "system_prompt_sections.#{section_id}.order must be between -10000 and 10000",
                code: "cybros.agent_profile_config.system_prompt_sections_order_out_of_range",
                details: { section_id: section_id, order: value },
              )
            end

            parsed[:order] = value
          end

          if cfg.key?("prompt_modes")
            value = cfg.fetch("prompt_modes", nil)
            unless value.is_a?(Array)
              AgentCore::ValidationError.raise!(
                "system_prompt_sections.#{section_id}.prompt_modes must be an Array of Strings",
                code: "cybros.agent_profile_config.system_prompt_sections_prompt_modes_must_be_an_array_of_strings",
                details: { section_id: section_id, value_class: value.class.name },
              )
            end

            modes =
              Array(value).map do |entry|
                entry.to_s.strip.downcase.tr("-", "_")
              end.uniq

            allowed = AgentCore::Resources::PromptInjections::PROMPT_MODES.map(&:to_s)
            invalid = modes - allowed
            if invalid.any?
              AgentCore::ValidationError.raise!(
                "system_prompt_sections.#{section_id}.prompt_modes must be one of: #{allowed.sort.join(", ")}",
                code: "cybros.agent_profile_config.system_prompt_sections_prompt_modes_must_be_one_of",
                details: { section_id: section_id, invalid_prompt_modes: invalid.sort },
              )
            end

            if modes.length > 2
              AgentCore::ValidationError.raise!(
                "system_prompt_sections.#{section_id}.prompt_modes is too large (max 2)",
                code: "cybros.agent_profile_config.system_prompt_sections_prompt_modes_too_large",
                details: { section_id: section_id, prompt_modes_count: modes.length },
              )
            end

            parsed[:prompt_modes] = modes.map(&:to_sym)
          end

          if cfg.key?("stability")
            raw_stability = cfg.fetch("stability", nil).to_s.strip.downcase.tr("-", "_")
            unless %w[prefix tail].include?(raw_stability)
              AgentCore::ValidationError.raise!(
                "system_prompt_sections.#{section_id}.stability must be prefix or tail",
                code: "cybros.agent_profile_config.system_prompt_sections_stability_must_be_prefix_or_tail",
                details: { section_id: section_id, stability: raw_stability },
              )
            end

            parsed[:stability] = raw_stability.to_sym
          end

          out[section_id] = parsed.freeze
        end

        out.freeze
      end

      private_class_method def self.system_prompt_sections_to_metadata(system_prompt_sections)
        raw = AgentCore::Utils.deep_stringify_keys(system_prompt_sections)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(section_id, cfg), out|
          cfg = cfg.is_a?(Hash) ? cfg : {}

          entry = {}
          entry["enabled"] = cfg.fetch("enabled") if cfg.key?("enabled")
          entry["order"] = cfg.fetch("order") if cfg.key?("order")
          entry["prompt_modes"] = Array(cfg.fetch("prompt_modes")).map(&:to_s) if cfg.key?("prompt_modes")
          entry["stability"] = cfg.fetch("stability").to_s if cfg.key?("stability")

          out[section_id.to_s] = entry
        end
      rescue StandardError
        {}
      end
    end
end
