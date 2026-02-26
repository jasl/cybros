# frozen_string_literal: true

module LLMProviders
  class ModelFetcher
    DEFAULT_TIMEOUT_S = 5

    def self.model_ids_for(provider, timeout_s: DEFAULT_TIMEOUT_S)
      client =
        SimpleInference::Client.new(
          base_url: provider.base_url,
          api_key: provider.api_key,
          headers: provider.headers || {},
          timeout: timeout_s,
          open_timeout: timeout_s,
          read_timeout: timeout_s,
        )

      client.models
    end
  end
end

