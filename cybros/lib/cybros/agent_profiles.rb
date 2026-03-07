module Cybros
  module AgentProfiles
    DEFAULT_PROFILE = "coding"
    DEFAULT_MEMORY_SEARCH_LIMIT = 5
    INPUT_POLICY_GLOBAL_DEFAULTS = {
      "input_coalescing" => {
        "enabled" => true,
        "window_ms" => 1500,
      },
      "running_input_policy" => "queue",
      "interrupted_output_policy" => "keep_context",
      "steer_capability" => false,
      "steer_cleanup_policy" => "none",
      "steer_after_side_effects" => false,
      "oversize" => {
        "single_message" => {
          "soft_threshold_ratio" => 0.25,
          "hard_threshold_ratio" => 0.5,
          "soft_strategy" => "compress_input",
          "hard_strategy" => "product_guard",
        },
        "multi_message" => {
          "strategy" => "compact_context",
        },
      },
    }.freeze

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

    INPUT_POLICY_OVERRIDES = {
      "coding" => {
        "interrupted_output_policy" => "discard_context",
        "steer_capability" => true,
      },
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
        directives_config: nil,
        system_prompt_section_overrides: {},
        input_policy: input_policy(key),
      }
    rescue StandardError
      {
        tool_patterns: PROFILES.fetch(DEFAULT_PROFILE),
        prompt_mode: :full,
        memory_search_limit: DEFAULT_MEMORY_SEARCH_LIMIT,
        prompt_injections: [],
        include_skill_locations: false,
        directives_config: nil,
        system_prompt_section_overrides: {},
        input_policy: input_policy(DEFAULT_PROFILE),
      }
    end

    def global_input_policy
      deep_dup_value(INPUT_POLICY_GLOBAL_DEFAULTS)
    end

    def input_policy(profile)
      global_input_policy.deep_merge(INPUT_POLICY_OVERRIDES.fetch(normalize(profile), {}).deep_dup)
    rescue StandardError
      global_input_policy
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

    def deep_dup_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, inner), out|
          out[key] = deep_dup_value(inner)
        end
      when Array
        value.map { |inner| deep_dup_value(inner) }
      when String
        value.dup
      else
        value
      end
    end
  end
end
