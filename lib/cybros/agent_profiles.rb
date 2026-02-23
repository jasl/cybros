# frozen_string_literal: true

module Cybros
  module AgentProfiles
    DEFAULT_PROFILE = "coding"
    DEFAULT_MEMORY_SEARCH_LIMIT = 5

    PROFILES = {
      "coding" => ["*"],
      "review" => ["*"],
      "subagent" => [],
      "repair" => ["*"],
    }.freeze

    PROMPT_MODES = {
      "coding" => :full,
      "review" => :full,
      "subagent" => :minimal,
      "repair" => :minimal,
    }.freeze

    MEMORY_SEARCH_LIMITS = {
      "coding" => DEFAULT_MEMORY_SEARCH_LIMIT,
      "review" => DEFAULT_MEMORY_SEARCH_LIMIT,
      "subagent" => 0,
      "repair" => 0,
    }.freeze

    PROMPT_INJECTION_SPECS = {
      "coding" => [
        { type: "repo_docs", filenames: ["AGENTS.md"], max_total_bytes: 50_000, order: 10, prompt_modes: [:full] },
      ],
      "review" => [
        { type: "repo_docs", filenames: ["AGENTS.md"], max_total_bytes: 50_000, order: 10, prompt_modes: [:full] },
      ],
      "subagent" => [],
      "repair" => [],
    }.freeze

    module_function

    def normalize(value)
      s = value.to_s.strip.downcase
      s = DEFAULT_PROFILE if s.empty?

      PROFILES.key?(s) ? s : DEFAULT_PROFILE
    rescue StandardError
      DEFAULT_PROFILE
    end

    def allowed_patterns(profile)
      PROFILES.fetch(normalize(profile))
    rescue StandardError
      PROFILES.fetch(DEFAULT_PROFILE)
    end

    def valid?(profile)
      PROFILES.key?(profile.to_s.strip.downcase)
    rescue StandardError
      false
    end

    def definition(profile)
      key = normalize(profile)

      {
        tool_patterns: allowed_patterns(key),
        prompt_mode: prompt_mode(key),
        memory_search_limit: memory_search_limit(key),
        prompt_injections: prompt_injection_specs(key),
        include_skill_locations: false,
        system_prompt_section_overrides: {},
      }
    rescue StandardError
      {
        tool_patterns: PROFILES.fetch(DEFAULT_PROFILE),
        prompt_mode: :full,
        memory_search_limit: DEFAULT_MEMORY_SEARCH_LIMIT,
        prompt_injections: [],
        include_skill_locations: false,
        system_prompt_section_overrides: {},
      }
    end

    def prompt_mode(profile)
      PROMPT_MODES.fetch(normalize(profile))
    rescue StandardError
      :full
    end

    def memory_search_limit(profile)
      MEMORY_SEARCH_LIMITS.fetch(normalize(profile))
    rescue StandardError
      DEFAULT_MEMORY_SEARCH_LIMIT
    end

    def prompt_injection_specs(profile)
      Array(PROMPT_INJECTION_SPECS.fetch(normalize(profile))).map do |spec|
        spec.is_a?(Hash) ? spec.dup : spec
      end
    rescue StandardError
      []
    end
  end
end
