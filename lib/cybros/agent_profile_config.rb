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
    ) do
      MAX_CONTEXT_TURNS = 1000
      MAX_MEMORY_SEARCH_LIMIT = 20
      MAX_REPO_DOCS_TOTAL_BYTES = 200_000
      MAX_TOOL_PATTERNS = 200
      MAX_TOOL_PATTERN_BYTES = 128

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

        new(
          base_profile: base_profile,
          context_turns: context_turns,
          prompt_mode: prompt_mode,
          memory_search_limit: memory_search_limit,
          tools_allowed: tools_allowed,
          repo_docs_enabled: repo_docs_enabled,
          repo_docs_max_total_bytes: repo_docs_max_total_bytes,
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
    end
end
