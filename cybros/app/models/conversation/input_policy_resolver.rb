class Conversation::InputPolicyResolver
  ACTION_LEVEL_INTERRUPTED_OUTPUT_POLICIES = %w[retry steer_current_turn].freeze

  def self.resolve(conversation:, app_override: nil, action: nil, interrupted_output_policy_override: nil)
    new(
      conversation: conversation,
      app_override: app_override,
      action: action,
      interrupted_output_policy_override: interrupted_output_policy_override,
    ).resolve
  end

  def initialize(conversation:, app_override: nil, action: nil, interrupted_output_policy_override: nil)
    @conversation = conversation
    @app_override = normalize_policy_hash(app_override)
    @action = action.to_s
    @interrupted_output_policy_override = interrupted_output_policy_override.to_s.presence
  end

  def resolve
    policy = base_policy
    policy.deep_merge!(conversation_override)
    policy.deep_merge!(app_override)

    if action.in?(ACTION_LEVEL_INTERRUPTED_OUTPUT_POLICIES) && interrupted_output_policy_override.present?
      policy["interrupted_output_policy"] = interrupted_output_policy_override
    end

    policy
  end

  private

  attr_reader :conversation, :app_override, :action, :interrupted_output_policy_override

  def conversation_override
    normalize_policy_hash(conversation.metadata&.dig("input_policy"))
  end

  def base_policy
    manifest_authoritative_program&.input_policy_config || Cybros::AgentProfiles.input_policy(profile_name)
  end

  def manifest_authoritative_program
    return nil if explicit_agent_profile_metadata?

    conversation.agent_program
  rescue StandardError
    nil
  end

  def explicit_agent_profile_metadata?
    agent = conversation.metadata&.dig("agent")
    return false unless agent.is_a?(Hash) && agent.key?("agent_profile")

    raw = agent.fetch("agent_profile", nil)
    raw.is_a?(Hash) || raw.to_s.strip.present?
  rescue StandardError
    false
  end

  def profile_name
    raw = conversation.metadata&.dig("agent", "agent_profile")

    if raw.is_a?(Hash) || (raw.is_a?(String) && raw.lstrip.start_with?("{"))
      Cybros::AgentProfileConfig.from_value(raw).base_profile
    else
      Cybros::AgentProfiles.normalize(raw)
    end
  rescue StandardError
    Cybros::AgentProfiles::DEFAULT_PROFILE
  end

  def normalize_policy_hash(value)
    hash =
      if value.respond_to?(:to_unsafe_h)
        value.to_unsafe_h
      elsif value.is_a?(Hash)
        value
      elsif value.respond_to?(:to_h)
        value.to_h
      end

    hash.is_a?(Hash) ? hash.deep_stringify_keys : {}
  end
end
