module RuntimeGovernance
  class ProviderCredentialLimiter
    def self.resolve!(selected_model_ref:)
      new(selected_model_ref: selected_model_ref).resolve!
    end

    def initialize(selected_model_ref:)
      @selected_model_ref = selected_model_ref.to_s
    end

    def resolve!
      provider_key, = Cybros::AgentRuntimeResolver.validate_model_ref!(model_ref: selected_model_ref).values_at(:provider_key, :model_key)
      provider_credential = LLMProviderCredential.find_by(provider_key: provider_key, status: "active")

      unless provider_credential
        AgentCore::ValidationError.raise!(
          "Provider credential missing. Please configure credentials and try again.",
          code: "cybros.runtime_governance.provider_credential_missing",
          details: { provider_key: provider_key },
        )
      end

      {
        provider_credential: provider_credential,
        snapshot: {
          "provider_key" => provider_credential.provider_key,
          "provider_credential_id" => provider_credential.id,
          "credential_type" => provider_credential.credential_type,
          "max_concurrent_requests" => provider_credential.max_concurrent_requests,
          "requests_per_minute" => provider_credential.requests_per_minute,
          "tokens_per_minute" => provider_credential.tokens_per_minute,
          "burst_limit" => provider_credential.burst_limit,
          "backoff_policy" => normalize_hash(provider_credential.backoff_policy),
        },
      }
    rescue AgentCore::ValidationError => e
      raise unless e.code == "cybros.llm.credential_missing"

      AgentCore::ValidationError.raise!(
        "Provider credential missing. Please configure credentials and try again.",
        code: "cybros.runtime_governance.provider_credential_missing",
        details: { provider_key: e.details[:provider_key] || e.details["provider_key"] },
      )
    end

    private

      attr_reader :selected_model_ref

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_stringify_keys : {}
      end
  end
end
