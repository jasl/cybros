class Conversation::InputGuard
  Result = Data.define(
    :classification,
    :estimated_tokens,
    :effective_prompt_budget_tokens,
    :soft_threshold_tokens,
    :hard_threshold_tokens,
    :compressed_content
  )

  def self.classify(conversation:, content:, input_policy:)
    new(conversation: conversation, content: content, input_policy: input_policy).classify
  end

  def initialize(conversation:, content:, input_policy:)
    @conversation = conversation
    @content = content.to_s
    @input_policy = input_policy.is_a?(Hash) ? input_policy : {}
  end

  def classify
    budget = effective_prompt_budget_tokens
    estimated = token_counter.count_text(@content)
    soft_threshold = threshold_tokens(path: %w[oversize single_message soft_threshold_ratio], budget: budget)
    hard_threshold = threshold_tokens(path: %w[oversize single_message hard_threshold_ratio], budget: budget)

    if estimated >= hard_threshold
      Result.new(
        classification: :hard,
        estimated_tokens: estimated,
        effective_prompt_budget_tokens: budget,
        soft_threshold_tokens: soft_threshold,
        hard_threshold_tokens: hard_threshold,
        compressed_content: nil,
      )
    elsif estimated >= soft_threshold
      Result.new(
        classification: :soft,
        estimated_tokens: estimated,
        effective_prompt_budget_tokens: budget,
        soft_threshold_tokens: soft_threshold,
        hard_threshold_tokens: hard_threshold,
        compressed_content: compressed_content_for(estimated_tokens: estimated, budget: budget),
      )
    else
      Result.new(
        classification: :normal,
        estimated_tokens: estimated,
        effective_prompt_budget_tokens: budget,
        soft_threshold_tokens: soft_threshold,
        hard_threshold_tokens: hard_threshold,
        compressed_content: nil,
      )
    end
  end

  private

    def effective_prompt_budget_tokens
      [(model_spec.fetch("context_window_tokens").to_i - reserved_output_tokens), 1].max
    end

    def reserved_output_tokens
      0
    end

    def threshold_tokens(path:, budget:)
      ratio = @input_policy.dig(*path)
      value = Float(ratio || 0, exception: false) || 0.0
      [1, (budget * value).floor].max
    end

    def compressed_content_for(estimated_tokens:, budget:)
      char_budget = [[(budget * 2), 120].max, 4000].min
      snippet = @content.each_char.take(char_budget).join

      <<~TEXT.strip
        [Compressed oversized input]
        Estimated input tokens: #{estimated_tokens}
        Effective prompt budget: #{budget}

        #{snippet}
      TEXT
    end

    def token_counter
      @token_counter ||=
        AgentCore::Resources::TokenCounter::Estimator.new(
          token_estimator: AgentCore::Tokenization::TokenEstimator.default,
          model_hint: model_spec.fetch("api_model").to_s,
        )
    rescue LoadError, StandardError
      AgentCore::Resources::TokenCounter::Heuristic.new
    end

    def model_spec
      @model_spec ||=
        begin
          resolution = Cybros::AgentRuntimeResolver.model_resolution_for(conversation: @conversation)
          Cybros::LLM::Catalog.effective.model(
            resolution.fetch(:provider_key),
            resolution.fetch(:model_key),
          )
        end
    end
end
